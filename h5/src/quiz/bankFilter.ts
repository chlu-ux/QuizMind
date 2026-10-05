import type { Bank, LocalQuestion } from '@/data/types'

/** One choice of the bank filter on the wrong-book and favourites lists. */
export interface BankOption {
  id: string
  name: string
  count: number
}

/** Shown for questions whose bank this device no longer knows (deleted on the server). */
export const UNKNOWN_BANK = '已删除的题库'

/**
 * The banks that have questions among [items], with how many, in the order of [banks]
 * (banks the device no longer lists come last, under a stand-in name; their questions
 * stay reachable).
 */
export function bankOptions(items: LocalQuestion[], banks: Bank[]): BankOption[] {
  const count = new Map<string, number>()
  for (const q of items) count.set(q.bank_id, (count.get(q.bank_id) ?? 0) + 1)
  const out: BankOption[] = []
  for (const b of banks) {
    const n = count.get(b.id)
    if (n) {
      out.push({ id: b.id, name: b.title, count: n })
      count.delete(b.id)
    }
  }
  for (const [id, n] of [...count].sort((a, b) => a[0].localeCompare(b[0]))) {
    out.push({ id, name: UNKNOWN_BANK, count: n })
  }
  return out
}

/** [items] of one bank, or all of them when [bankId] is empty. */
export function inBank(items: LocalQuestion[], bankId: string): LocalQuestion[] {
  return bankId ? items.filter((q) => q.bank_id === bankId) : items
}

const KEY = 'quizmind.listBank.'

/** The bank last picked on a list, for this browser session only (so a new visit never starts on a narrowed list). */
export function rememberedBank(kind: string): string {
  try {
    return sessionStorage.getItem(KEY + kind) ?? ''
  } catch {
    return ''
  }
}

export function rememberBank(kind: string, bankId: string) {
  try {
    if (bankId) sessionStorage.setItem(KEY + kind, bankId)
    else sessionStorage.removeItem(KEY + kind)
  } catch {
    /* private mode: the choice just is not remembered */
  }
}
