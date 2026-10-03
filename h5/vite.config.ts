import { fileURLToPath, URL } from 'node:url'
import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vitest/config'

// The Go server serves this app under /m/ (see server/internal/httpapi), so
// assets are built relative to that base. In dev, API calls go to the Go server.
export default defineConfig({
  base: '/m/',
  plugins: [vue()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  server: {
    port: 5174,
    host: true,
    proxy: {
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: false },
      '/healthz': { target: 'http://127.0.0.1:8080', changeOrigin: false },
    },
  },
  build: { outDir: 'dist', chunkSizeWarningLimit: 600 },
  test: { environment: 'node', setupFiles: ['fake-indexeddb/auto'] },
})
