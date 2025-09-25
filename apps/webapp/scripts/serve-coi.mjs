#!/usr/bin/env node
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import url from 'node:url'

const __filename = url.fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const root = path.resolve(__dirname, '..', 'public')
const port = process.env.PORT ? Number(process.env.PORT) : 5500

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.onnx': 'application/octet-stream',
  '.txt': 'text/plain; charset=utf-8',
}

function send(res, status, body, ext) {
  res.statusCode = status
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin')
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp')
  if (ext && mime[ext]) res.setHeader('Content-Type', mime[ext])
  res.end(body)
}

function safeJoin(rootDir, reqPath) {
  const p = path.normalize(decodeURIComponent(reqPath.split('?')[0]))
  const full = path.join(rootDir, p)
  if (!full.startsWith(rootDir)) return null
  return full
}

const server = http.createServer((req, res) => {
  const urlPath = req.url || '/'
  let filePath = safeJoin(root, urlPath)
  if (!filePath) return send(res, 403, 'Forbidden')

  fs.stat(filePath, (err, stat) => {
    if (err) {
      // default file
      const fallback = path.join(root, 'offline.html')
      return fs.readFile(fallback, (e2, buf) => {
        if (e2) return send(res, 404, 'Not found')
        send(res, 200, buf, '.html')
      })
    }
    if (stat.isDirectory()) {
      const indexFile = path.join(filePath, 'index.html')
      fs.readFile(indexFile, (e3, buf) => {
        if (e3) {
          const fallback = path.join(filePath, 'offline.html')
          return fs.readFile(fallback, (e4, buf2) => {
            if (e4) return send(res, 404, 'Not found')
            send(res, 200, buf2, '.html')
          })
        }
        send(res, 200, buf, '.html')
      })
    } else {
      fs.readFile(filePath, (e5, buf) => {
        if (e5) return send(res, 404, 'Not found')
        send(res, 200, buf, path.extname(filePath))
      })
    }
  })
})

server.listen(port, () => {
  console.log(`Serving ${root} with COOP/COEP at http://127.0.0.1:${port}/offline.html`)
})
