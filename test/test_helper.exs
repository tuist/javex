{:ok, _} = Javex.Runtime.start_link()

# JIT the shared compiler provider before async tests start their call deadlines.
# Cold native compilation can exceed five seconds on slower release runners.
{:ok, _} = Javex.compile("", timeout: 30_000)

ExUnit.start()
