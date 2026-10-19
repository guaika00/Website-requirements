import { writeFileSync } from 'node:fs';
const url = (process.env.SUPABASE_URL || '').trim();
const key = (process.env.SUPABASE_PUBLISHABLE_KEY || '').trim();
if (!/^https:\/\/[a-z0-9.-]+\.supabase\.co\/?$/i.test(url) || !key) {
 console.error('Missing/invalid SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY. Configure both in Vercel Environment Variables.');
 process.exit(1);
}
writeFileSync(new URL('../public/config.js', import.meta.url), `window.BOARD_CONFIG=${JSON.stringify({supabaseUrl:url.replace(/\/$/,''),supabaseKey:key})};\n`);
console.log('Static Supabase client config generated.');
