import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      '/v1': 'http://localhost:8001',
      '/uploads': 'http://localhost:8001',
      '/ws': { target: 'ws://localhost:8001', ws: true },
    },
  },
})
