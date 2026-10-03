const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

/**
 * A 26-character ULID: 48-bit millisecond timestamp + 80 random bits, Crockford
 * base32. Sorts by creation time and is safe as an idempotency key.
 */
export function newUlid(now: number = Date.now()): string {
  let t = now
  const time: string[] = []
  for (let i = 0; i < 10; i++) {
    time.unshift(ALPHABET[t % 32])
    t = Math.floor(t / 32)
  }
  const rand = new Uint8Array(16)
  crypto.getRandomValues(rand)
  let out = time.join('')
  for (let i = 0; i < 16; i++) out += ALPHABET[rand[i] % 32]
  return out
}
