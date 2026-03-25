-- 1. PROFILES TABEL
CREATE TABLE public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name text NOT NULL DEFAULT 'User',
    avatar_url text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2. ROOMS TABEL (Met nieuwe preview kolommen)
CREATE TABLE public.rooms (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    avatar_url text,
    has_password boolean NOT NULL DEFAULT false,
    is_visible boolean NOT NULL DEFAULT true,
    is_direct boolean NOT NULL DEFAULT false,
    salt text NOT NULL,
    created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    allowed_users text[] NOT NULL DEFAULT '{*}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- NIEUW: Kolommen voor Lobby Preview
    last_message_at timestamptz,
    last_message_content text,
    last_message_user_name text,
    last_message_user_id uuid
);

-- 3. ROOM PASSWORDS TABEL
CREATE TABLE public.room_passwords (
    room_id uuid PRIMARY KEY REFERENCES public.rooms(id) ON DELETE CASCADE,
    password_hash text NOT NULL
);

-- 4. MESSAGES TABEL
CREATE TABLE public.messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    user_name text NOT NULL,
    content text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

-- 5. INDEXEN
CREATE INDEX IF NOT EXISTS idx_messages_room_id_created_at ON public.messages(room_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rooms_created_by ON public.rooms(created_by);
CREATE INDEX IF NOT EXISTS idx_profiles_id ON public.profiles(id);
CREATE INDEX IF NOT EXISTS idx_rooms_allowed_users ON public.rooms USING GIN (allowed_users);

-- 6. ROW LEVEL SECURITY
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_passwords ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- 7. POLICIES
DROP POLICY IF EXISTS profiles_select_all ON public.profiles;
CREATE POLICY profiles_select_all ON public.profiles FOR SELECT USING (true);

DROP POLICY IF EXISTS profiles_insert_self ON public.profiles;
CREATE POLICY profiles_insert_self ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS profiles_update_self ON public.profiles;
CREATE POLICY profiles_update_self ON public.profiles FOR UPDATE USING (auth.uid() = id);

DROP POLICY IF EXISTS rooms_select_visible ON public.rooms;
CREATE POLICY rooms_select_visible ON public.rooms FOR SELECT USING (
    auth.uid() = created_by
    OR allowed_users @> ARRAY[auth.uid()::text]
    OR allowed_users @> ARRAY['*']
);

DROP POLICY IF EXISTS rooms_insert_authenticated ON public.rooms;
CREATE POLICY rooms_insert_authenticated ON public.rooms FOR INSERT WITH CHECK (
    auth.role() = 'authenticated' AND auth.uid() = created_by
);

DROP POLICY IF EXISTS rooms_delete_policy ON public.rooms;
CREATE POLICY rooms_delete_policy ON public.rooms FOR DELETE USING (
    auth.uid() = created_by
    OR (is_direct = true AND allowed_users @> ARRAY[auth.uid()::text])
);

DROP POLICY IF EXISTS rooms_update_creator ON public.rooms;
CREATE POLICY rooms_update_creator ON public.rooms FOR UPDATE USING (auth.uid() = created_by);

DROP POLICY IF EXISTS room_passwords_block_direct ON public.room_passwords;
CREATE POLICY room_passwords_block_direct ON public.room_passwords FOR ALL USING (false);

DROP POLICY IF EXISTS messages_select_room ON public.messages;
CREATE POLICY messages_select_room ON public.messages FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.rooms
        WHERE rooms.id = messages.room_id
        AND (
            rooms.created_by = auth.uid()
            OR rooms.allowed_users @> ARRAY['*']
            OR rooms.allowed_users @> ARRAY[auth.uid()::text]
        )
    )
);

DROP POLICY IF EXISTS messages_insert_authenticated ON public.messages;
CREATE POLICY messages_insert_authenticated ON public.messages FOR INSERT WITH CHECK (
    auth.role() = 'authenticated' AND auth.uid() = user_id
);

DROP POLICY IF EXISTS messages_update_own ON public.messages;
CREATE POLICY messages_update_own ON public.messages FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (
    auth.uid() = user_id
    AND (content = '/' OR created_at > now() - interval '15 minutes')
);

-- 8. FUNCTIES

-- User Creation Handler
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$ BEGIN
    INSERT INTO public.profiles (id, full_name, avatar_url, updated_at)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data ->> 'full_name', 'User'),
        NEW.raw_user_meta_data ->> 'avatar_url',
        NOW()
    )
    ON CONFLICT (id) DO UPDATE SET
        full_name = COALESCE(NEW.raw_user_meta_data ->> 'full_name', profiles.full_name),
        avatar_url = COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', profiles.avatar_url),
        updated_at = NOW();
    RETURN NEW;
END; $$;

-- Updated At Handler
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
    NEW.updated_at = NOW(); RETURN NEW;
END; $$;

-- NIEUW: Lobby Preview Update Function
CREATE OR REPLACE FUNCTION public.update_room_last_message()
RETURNS TRIGGER AS $$ BEGIN
  UPDATE public.rooms
  SET last_message_at = CASE WHEN TG_OP = 'INSERT' THEN NEW.created_at ELSE rooms.last_message_at END,
      last_message_content = NEW.content,
      last_message_user_name = NEW.user_name,
      last_message_user_id = NEW.user_id
  WHERE id = NEW.room_id;
  RETURN NEW;
END;
 $$ LANGUAGE plpgsql;

-- Room Password Setter
CREATE OR REPLACE FUNCTION public.set_room_password(p_room_id uuid, p_hash text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.rooms WHERE id = p_room_id AND created_by = auth.uid()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
    IF p_hash IS NULL THEN DELETE FROM public.room_passwords WHERE room_id = p_room_id;
    ELSE INSERT INTO public.room_passwords (room_id, password_hash) VALUES (p_room_id, p_hash) ON CONFLICT (room_id) DO UPDATE SET password_hash = EXCLUDED.password_hash; END IF;
END; $$;

-- Room Password Verifier
CREATE OR REPLACE FUNCTION public.verify_room_password(p_room_id uuid, p_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$ BEGIN RETURN EXISTS (SELECT 1 FROM public.room_passwords WHERE room_id = p_room_id AND password_hash = p_hash); END; $$;

-- Room Access Check
CREATE OR REPLACE FUNCTION public.can_access_room(p_room_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$ DECLARE r_allowed text[]; r_creator uuid;
BEGIN
    SELECT allowed_users, created_by INTO r_allowed, r_creator FROM public.rooms WHERE id = p_room_id;
    IF r_creator IS NULL THEN RETURN false; END IF;
    IF r_creator = auth.uid() THEN RETURN true; END IF;
    IF r_allowed @> ARRAY[auth.uid()::text] THEN RETURN true; END IF;
    IF r_allowed @> ARRAY['*'] THEN RETURN true; END IF;
    RETURN false;
END; $$;

-- 9. TRIGGERS
DROP TRIGGER IF EXISTS on_profiles_updated ON public.profiles;
CREATE TRIGGER on_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS on_message_update ON public.messages;
CREATE TRIGGER on_message_update BEFORE UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT OR UPDATE OF raw_user_meta_data ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- NIEUW: Trigger voor lobby updates (Insert en Update)
DROP TRIGGER IF EXISTS on_message_change ON public.messages;
CREATE TRIGGER on_message_change
AFTER INSERT OR UPDATE ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.update_room_last_message();

-- 10. REALTIME
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
