import { fileURLToPath, URL } from 'node:url'
import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vitest/config'

// In dev, API calls go to the Go server; in production the Go binary serves
// this app itself, so no proxy or CORS is involved.
export default defineConfig({
  plugins: [vue()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  server: {
    port: 5173,
    proxy: { '/admin': { target: 'http://127.0.0.1:8080', changeOrigin: false } },
  },
  build: { outDir: 'dist', chunkSizeWarningLimit: 1200 },
  test: { environment: 'node' },
})
