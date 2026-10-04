const key = (scope: string) => `quizmind.seqpos.${scope}`

/** Id of the question the learner was on when they last left 按顺序刷题 in a bank; null if none. Kept on this device only. */
export function sequentialPosition(scope: string): string | null {
  try {
    return localStorage.getItem(key(scope))
  } catch {
    return null
  }
}

export function setSequentialPosition(scope: string, questionId: string | null) {
  try {
    if (questionId === null) localStorage.removeItem(key(scope))
    else localStorage.setItem(key(scope), questionId)
  } catch {
    /* private mode: the position is just not remembered */
  }
}
