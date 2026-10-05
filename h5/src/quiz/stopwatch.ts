/**
 * Counts time only while the page is visible: a tab in the background or a phone
 * with the screen off is not studying. [lap] hands out what has been counted since
 * the previous lap, so one stopwatch can time a series of consecutive stretches.
 */
export class Stopwatch {
  private counted = 0
  private since: number | null
  private shown: boolean

  constructor(
    private readonly now: () => number = Date.now,
    visible = true,
  ) {
    this.shown = visible
    this.since = visible ? now() : null
  }

  /** Tells the stopwatch the page was hidden or shown again. */
  setVisible(visible: boolean) {
    if (visible === this.shown) return
    this.shown = visible
    if (visible) {
      this.since = this.now()
    } else if (this.since !== null) {
      this.counted += Math.max(this.now() - this.since, 0)
      this.since = null
    }
  }

  /** Milliseconds counted since the last lap, which a new lap then starts from. */
  lap(): number {
    let ms = this.counted
    if (this.since !== null) {
      const t = this.now()
      ms += Math.max(t - this.since, 0)
      this.since = t
    }
    this.counted = 0
    return ms
  }
}
