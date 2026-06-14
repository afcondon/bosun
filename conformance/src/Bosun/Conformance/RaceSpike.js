// Node twin of the Go race-spike foreign (required by purs; the real test is the
// Go column under -race). Node is single-threaded, so this just forces the CAF n
// times sequentially — no concurrency to probe here.
export const forceConcurrentlyImpl = (n, f) => {
  const results = [];
  for (let i = 0; i < n; i++) results.push(f());
  return results;
};
