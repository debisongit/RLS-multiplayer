import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const here = path.dirname(fileURLToPath(import.meta.url))
export default defineConfig({
  plugins: [vue()],
  resolve: { alias: { '@/bridge': path.resolve(here, 'bridge-mock.js') } },
  test: { environment: 'jsdom', include: ['app.test.js'] },
})
