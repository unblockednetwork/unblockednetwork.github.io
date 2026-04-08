"use strict";

class HRN_Core {
  constructor() {
    this.config = {
      src: "https://cdn.jsdelivr.net/gh/un-zynq/un-zynq.github.io/games2.json",
      cdn: "https://cdn.jsdelivr.net/gh/un-zynq/thumbnails",
    };

    this.all = [];
    this.filtered = [];
    this.favorites = this._initStorage();
    this.deviceType = 2;
  }

  async init(options = {}) {
    const {
      mode = "all",
      search = "",
      sort = "name",
      src = this.config.src,
      cdn = this.config.cdn,
    } = options;

    this.config.src = src;
    this.config.cdn = cdn;

    this._detectDevice();
    await this._loadData(sort);

    if (search) this.search(search);
    if (mode === "supported") this.filterSupported();
    if (mode === "favs") this.filterFavorites();

    return this;
  }

  _detectDevice() {
    const n = navigator;
    const ua = n.userAgent;
    const touchPoints = n.maxTouchPoints || 0;
    const hasFinePointer = window.matchMedia("(pointer: fine)").matches;
    const hasHover = window.matchMedia("(hover: hover)").matches;

    const canvas = document.createElement("canvas");
    const gl =
      canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
    const debugInfo = gl?.getExtension("WEBGL_debug_renderer_info");
    const renderer = debugInfo
      ? gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL)
      : "";

    let scores = { desktop: 0, mobile: 0 };

    if (/Win|Mac|Linux/i.test(ua)) scores.desktop += 15;
    if (ua.includes("x64") || ua.includes("wow64")) scores.desktop += 10;
    if (hasFinePointer && hasHover) scores.desktop += 20;
    if (/Intel|Nvidia|AMD|Direct3D|GeForce/i.test(renderer))
      scores.desktop += 25;

    if (/Android|iPhone|iPad|iPod/i.test(ua)) scores.mobile += 20;
    if (/Adreno|Mali|PowerVR|Apple GPU/i.test(renderer)) scores.mobile += 25;

    if (scores.desktop > scores.mobile) {
      this.deviceType = touchPoints > 0 ? 1 : 2;
    } else if (/Macintosh/i.test(ua) && touchPoints > 1) {
      this.deviceType = 4;
    } else {
      const isLarge =
        window.screen.width >= 1024 ||
        (window.screen.width >= 768 && touchPoints > 1);
      this.deviceType = isLarge ? 4 : 3;
    }
  }

  async _loadData(sortKey) {
    try {
      const response = await fetch(this.config.src);
      const data = await response.json();
      const library = [];

      data.forEach((category) => {
        Object.entries(category).forEach(([base, games]) => {
          Object.entries(games).forEach(([alias, meta]) => {
            library.push({
              name: meta.name || alias,
              alias: alias,
              url: `${base}/${alias}`,
              thumb: `${this.config.cdn}/${base}/${alias}.webp`,
              devices: meta.devices
                ? String(meta.devices).split(",").map(Number)
                : null,
              get isSupported() {
                return this.devices?.includes(window.HRN.deviceType) ?? true;
              },
              get isFavorite() {
                return window.HRN.isFavorite(this.alias);
              },
            });
          });
        });
      });

      this.all = library.sort((a, b) =>
        (a[sortKey] || "").localeCompare(b[sortKey] || ""),
      );
      this.filtered = [...this.all];
    } catch (err) {
      console.error("HRN Core Error:", err);
    }
  }

  search(query) {
    const q = query?.toLowerCase().trim();
    this.filtered = q
      ? this.all.filter(
          (g) =>
            g.name.toLowerCase().includes(q) ||
            g.alias.toLowerCase().includes(q),
        )
      : [...this.all];
    return this;
  }

  filterFavorites() {
    this.filtered = this.filtered.filter((g) => g.isFavorite);
    return this;
  }

  filterSupported() {
    this.filtered = this.filtered.filter((g) => g.isSupported);
    return this;
  }

  reset() {
    this.filtered = [...this.all];
    return this;
  }

  get list() {
    return this.filtered;
  }

  isFavorite(alias) {
    return this.favorites.has(alias);
  }

  toggleFavorite(alias) {
    this.favorites.has(alias)
      ? this.favorites.delete(alias)
      : this.favorites.add(alias);
    localStorage.setItem("hrn_favs", JSON.stringify([...this.favorites]));
    return this;
  }

  _initStorage() {
    try {
      const data = localStorage.getItem("hrn_favs");
      return new Set(data ? JSON.parse(data) : []);
    } catch {
      return new Set();
    }
  }
}

const HRN = new HRN_Core();

if (typeof exports === "object" && typeof module !== "undefined") {
  module.exports = HRN;
} else if (typeof define === "function" && define.amd) {
  define([], () => HRN);
}

window.HRN = HRN;
export default HRN;
