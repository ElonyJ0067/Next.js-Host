const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.join(__dirname, '..');
const out = path.join(root, 'public', 'project.tar.gz');
const tempOut = path.join(os.tmpdir(), 'driver-fix-project.tar.gz');

const files = [
  'package.json',
  'package-lock.json',
  'app',
  'tailwind.config.js',
  'next.config.js',
  'postcss.config.js',
  'tsconfig.json',
  'next-env.d.ts',
  'netlify.toml',
  '.nvmrc',
];

if (fs.existsSync(out)) fs.unlinkSync(out);
if (fs.existsSync(tempOut)) fs.unlinkSync(tempOut);

const args = files.filter((f) => fs.existsSync(path.join(root, f)));
execSync(`tar czf "${tempOut}" ${args.join(' ')}`, { cwd: root, stdio: 'inherit' });

fs.copyFileSync(tempOut, out);
fs.unlinkSync(tempOut);
console.log('Created public/project.tar.gz');
