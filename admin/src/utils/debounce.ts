export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | undefined
  const wrapped = (...a: A) => {
    clearTimeout(t)
    t = setTimeout(() => fn(...a), ms)
  }
  wrapped.cancel = () => clearTimeout(t)
  return wrapped
}
