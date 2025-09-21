import { defineConfig } from 'vite'

export default defineConfig({
  // Avoid SPA history fallback serving index.html for missing JSON/ONNX under /models
  appType: 'mpa',
  root: '.',
  publicDir: 'public',
  server: {
    host: '127.0.0.1',
    port: 5174,
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
  },
  optimizeDeps: {
    exclude: [],
  },
});
