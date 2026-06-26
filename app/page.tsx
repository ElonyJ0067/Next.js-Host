const siteUrl =
  process.env.NEXT_PUBLIC_SITE_URL ||
  'https://driver-fix-238308.netlify.app';

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-10 p-8">
      <div className="text-center">
        <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">
          Driver Fix
        </h1>
        <p className="mt-3 text-slate-400">
          Next.js · Tailwind CSS v3 · tailwind-animates
        </p>
      </div>

      <div className="flex flex-wrap items-center justify-center gap-6">
        <div className="animate-bounce rounded-2xl bg-indigo-500 px-8 py-6 text-lg font-semibold shadow-lg shadow-indigo-500/30">
          Bounce
        </div>
        <div className="animate-pulse rounded-2xl bg-emerald-500 px-8 py-6 text-lg font-semibold shadow-lg shadow-emerald-500/30">
          Pulse
        </div>
        <div className="animate-spin rounded-2xl border-4 border-slate-600 border-t-cyan-400 px-8 py-6 text-lg font-semibold">
          &nbsp;
        </div>
      </div>

      <p className="max-w-md text-center text-sm text-slate-500">
        Plugin defaults: duration 1s · delay 500ms · iteration count 1
      </p>

      <a
        href={siteUrl}
        className="text-sm text-cyan-400/80 transition hover:text-cyan-300"
        target="_blank"
        rel="noopener noreferrer"
      >
        {siteUrl.replace(/^https:\/\//, '')}
      </a>
    </main>
  );
}
