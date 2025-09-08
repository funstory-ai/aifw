import { defineConfig } from 'vite'
import fs from 'node:fs'
import path from 'node:path'

export default defineConfig({
  // Avoid SPA history fallback serving index.html for missing JSON/ONNX under /models
  appType: 'mpa',
  server: {
    host: '127.0.0.1',
    port: 5173,
    open: true,
    configureServer(server) {
      const ROOT = process.cwd()
      const MODELS_ROOT = path.join(ROOT, 'public', 'models')
      // WASM assets are copied to public/wasm during prep; no need to read node_modules at runtime
      server.middlewares.use((req, res, next) => {
        const raw = req.url || ''
        if (!raw.startsWith('/models/')) return next()
        // strip query/hash
        let pathname = raw
        try {
          const u = new URL(raw, 'http://127.0.0.1')
          pathname = u.pathname
        } catch (_) {}
        const url = pathname
        const rel = decodeURIComponent(url.replace(/^\/models\//, ''))
        const abs = path.join(MODELS_ROOT, rel)
        if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
          const stat = fs.statSync(abs)
          const ext = path.extname(abs).toLowerCase()
          if (ext === '.json') res.setHeader('Content-Type', 'application/json')
          else if (ext === '.txt') res.setHeader('Content-Type', 'text/plain; charset=utf-8')
          else if (ext === '.onnx') res.setHeader('Content-Type', 'application/octet-stream')
          else if (ext === '.wasm') res.setHeader('Content-Type', 'application/wasm')
          else if (ext === '.js') res.setHeader('Content-Type', 'application/javascript')
          res.setHeader('Cache-Control', 'no-cache')
          res.setHeader('Accept-Ranges', 'bytes')

          const range = req.headers['range']
          if (range) {
            const m = /bytes=(\d*)-(\d*)/.exec(String(range))
            let start = 0
            let end = stat.size - 1
            if (m) {
              if (m[1]) start = parseInt(m[1], 10)
              if (m[2]) end = parseInt(m[2], 10)
            }
            if (start > end || isNaN(start) || isNaN(end)) {
              res.statusCode = 416
              res.setHeader('Content-Range', `bytes */${stat.size}`)
              return res.end()
            }
            res.statusCode = 206
            res.setHeader('Content-Range', `bytes ${start}-${end}/${stat.size}`)
            res.setHeader('Content-Length', String(end - start + 1))
            fs.createReadStream(abs, { start, end }).pipe(res)
            return
          }

          res.statusCode = 200
          res.setHeader('Content-Length', String(stat.size))
          fs.createReadStream(abs).pipe(res)
          return
        }
        res.statusCode = 404
        res.end('Not found')
      })
    },
  },
})
