import { defineConfig } from 'vite'
import path from 'node:path'
import fs from 'node:fs'

export default defineConfig({
  build: {
    lib: {
      entry: path.resolve(__dirname, 'libaifw.js'),
      name: 'libaifw-js',
      fileName: () => 'aifw-js.js',
      formats: ['es'],
    },
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      external: ['@xenova/transformers'],
    },
  },
})
