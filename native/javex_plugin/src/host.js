(() => {
  const dispatch = globalThis.__javex_dispatch;
  Reflect.deleteProperty(globalThis, "__javex_dispatch");
  globalThis.Javex = Object.freeze({Host: Object.freeze({call(name, argument) {
    if (typeof name !== "string" || !name.length || new TextEncoder().encode(name).length > 128) {
      throw new TypeError("Callback name must contain 1–128 UTF-8 bytes");
    }
    if (argument === undefined) throw new TypeError("Callback argument must be JSON-compatible");
    const [kind, result] = JSON.parse(dispatch(JSON.stringify({name, argument})));
    if (kind === "ok") return result;
    const error = new Error(result.message);
    error.name = "HostError";
    error.code = result.code;
    throw error;
  }})});
})();
