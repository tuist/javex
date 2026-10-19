(function (maxCalls, maxConcurrent, maxInput) {
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const encode = new TextEncoder().encode.bind(new TextEncoder());
  const PromiseClass = Promise;
  const ErrorClass = Error;
  const TypeErrorClass = TypeError;
  const pending = new Map();
  const get = pending.get.bind(pending);
  const set = pending.set.bind(pending);
  const remove = pending.delete.bind(pending);
  const size = Object.getOwnPropertyDescriptor(Map.prototype, "size").get.bind(pending);
  let requests = "";
  let count = 0;
  let fatal = false;

  const call = (name, argument) => {
    const id = ++count;
    if (id > maxCalls || size() >= maxConcurrent) {
      fatal = true;
      throw new ErrorClass("Callback limit exceeded");
    }
    return new PromiseClass((resolve, reject) => {
      if (typeof name !== "string" || name.length === 0 || encode(name).length > 128) {
        reject(new TypeErrorClass("Callback name must be a non-empty string of at most 128 UTF-8 bytes"));
        return;
      }
      const json = stringify(argument);
      if (json === undefined) {
        reject(new TypeErrorClass("Callback argument must be JSON"));
        return;
      }
      if (encode(json).length > maxInput) {
        fatal = true;
        throw new ErrorClass("Callback input limit exceeded");
      }
      set(id, {resolve, reject});
      // Only user arguments go through toJSON. Private protocol records must
      // not inherit guest hooks that could rewrite grants, quotas or completion.
      requests += (requests ? "," : "") +
        `{"id":${id},"name":${stringify(name)},"argument":${stringify(json)}}`;
    });
  };
  Object.defineProperty(globalThis, "Javex", {
    value: Object.freeze({Host: Object.freeze({call})}),
    writable: false,
    configurable: false
  });

  return (completions, mode) => {
    const values = parse(completions);
    for (let i = 0; i < values.length; i++) {
      const completion = values[i];
      const promise = get(completion.id);
      if (!promise) throw new ErrorClass("Unknown callback completion");
      remove(completion.id);
      if (completion.ok) promise.resolve(parse(completion.value));
      else {
        const error = new ErrorClass(completion.message);
        error.name = "HostError";
        error.code = completion.code;
        promise.reject(error);
      }
    }
    if (mode === 0) return;
    const done = mode === 2;
    const out = requests;
    requests = "";
    return `{"done":${done},"fatal":${fatal},"requests":[${done ? "" : out}]}`;
  };
})
