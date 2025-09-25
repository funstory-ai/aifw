#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true })
}

function copyFile(src, destDir) {
  ensureDir(destDir)
  const dest = path.join(destDir, path.basename(src))
  fs.copyFileSync(src, dest)
  console.log('[copy]', src, '->', dest)
}

function copyDir(src, dest) {
  ensureDir(dest)
  for (const e of fs.readdirSync(src)) {
    const s = path.join(src, e)
    const d = path.join(dest, e)
    const st = fs.statSync(s)
    if (st.isDirectory()) copyDir(s, d)
    else copyFile(s, dest)
  }
}

async function resolveAifwJsDist() {
  // Prefer installed package dist
  const nm = path.resolve(process.cwd(), 'node_modules', '@oneaifw', 'aifw-js', 'dist')
  if (fs.existsSync(nm)) return nm
  // Fallback to workspace dist
  const ws = path.resolve(process.cwd(), '..', '..', 'libs', 'aifw-js', 'dist')
  if (fs.existsSync(ws)) return ws
  throw new Error('cannot locate @oneaifw/aifw-js dist folder')
}

async function main() {
  const distDir = await resolveAifwJsDist()
  const outPublic = path.resolve(process.cwd(), 'public')
  ensureDir(outPublic)

  // Copy entire dist to vendor/aifw-js (no top-level mirrors)
  const vendorRoot = path.join(outPublic, 'vendor', 'aifw-js')
  copyDir(distDir, vendorRoot)

  const offlineHtmlPath = path.join(path.resolve(process.cwd()), 'aifw-offline.html')
  copyFile(offlineHtmlPath, outPublic)

}

main().catch((e) => { console.error(e); process.exit(1); })
