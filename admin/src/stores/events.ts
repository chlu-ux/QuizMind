import { defineStore } from 'pinia'
import { ref } from 'vue'
import { getToken } from '@/api/client'
import type { ServerEvent } from '@/api/types'

type Listener = (e: ServerEvent) => void

/**
 * One shared EventSource for the whole app. The server pushes job and
 * document progress; views subscribe to refresh themselves.
 *
 * EventSource cannot send an Authorization header, so the token travels as a
 * query parameter (the server never logs query strings).
 */
export const useEvents = defineStore('events', () => {
  const connected = ref(false)
  const listeners = new Set<Listener>()
  let source: EventSource | null = null

  function connect() {
    if (source) return
    const t = getToken()
    const url = '/admin/events' + (t ? `?access_token=${encodeURIComponent(t)}` : '')
    const es = new EventSource(url)
    source = es
    es.onopen = () => (connected.value = true)
    es.onerror = () => (connected.value = false) // EventSource retries by itself
    for (const type of ['job', 'document']) {
      es.addEventListener(type, (ev) => {
        try {
          const data = JSON.parse((ev as MessageEvent).data) as ServerEvent
          listeners.forEach((l) => l(data))
        } catch {
          /* ignore malformed event */
        }
      })
    }
  }

  function disconnect() {
    source?.close()
    source = null
    connected.value = false
  }

  /** Subscribe; returns an unsubscribe function. */
  function on(fn: Listener) {
    listeners.add(fn)
    return () => listeners.delete(fn)
  }

  return { connected, connect, disconnect, on }
})
