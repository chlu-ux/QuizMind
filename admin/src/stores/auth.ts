import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api, getToken, setToken, setUnauthorizedHandler } from '@/api/client'

export const useAuth = defineStore('auth', () => {
  const token = ref(getToken())
  /** True once we know the server accepts our credentials (or needs none). */
  const authed = ref(false)
  const checked = ref(false)

  async function check(): Promise<boolean> {
    try {
      await api.probe()
      authed.value = true
    } catch {
      authed.value = false
    }
    checked.value = true
    return authed.value
  }

  async function login(t: string): Promise<boolean> {
    setToken(t)
    token.value = t
    return check()
  }

  function logout() {
    setToken('')
    token.value = ''
    authed.value = false
  }

  setUnauthorizedHandler(() => {
    authed.value = false
  })

  return { token, authed, checked, check, login, logout }
})
