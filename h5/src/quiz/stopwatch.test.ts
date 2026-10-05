import { describe, expect, it } from 'vitest'
import { Stopwatch } from './stopwatch'

describe('Stopwatch', () => {
  it('hands out the time since the last lap', () => {
    let t = 1000
    const w = new Stopwatch(() => t)
    t += 5000
    expect(w.lap()).toBe(5000)
    t += 2000
    expect(w.lap()).toBe(2000)
    expect(w.lap()).toBe(0)
  })

  it('does not count the time a page was hidden', () => {
    let t = 0
    const w = new Stopwatch(() => t)
    t += 3000
    w.setVisible(false)
    t += 60_000 // phone on the table
    expect(w.lap()).toBe(3000)
    t += 60_000
    expect(w.lap()).toBe(0) // still hidden
    w.setVisible(true)
    t += 1500
    expect(w.lap()).toBe(1500)
  })

  it('starts paused for a page opened in the background', () => {
    let t = 0
    const w = new Stopwatch(() => t, false)
    t += 10_000
    expect(w.lap()).toBe(0)
    w.setVisible(true)
    t += 400
    expect(w.lap()).toBe(400)
  })
})
