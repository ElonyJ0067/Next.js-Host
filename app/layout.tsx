import type { Metadata } from 'next';
import './globals.css';

const siteUrl =
  process.env.NEXT_PUBLIC_SITE_URL ||
  'https://driver-fix-238308.netlify.app';

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: 'Driver Fix',
  description: 'Next.js + Tailwind CSS v3 + tailwind-animates',
  openGraph: {
    title: 'Driver Fix',
    url: siteUrl,
    siteName: 'Driver Fix',
    type: 'website',
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-slate-950 text-slate-100 antialiased">
        {children}
      </body>
    </html>
  );
}
