import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Petepete",
  description: "Bayar patungan grup olahraga tanpa install aplikasi.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="id" className="h-full antialiased">
      <body className="min-h-full flex flex-col font-sans">{children}</body>
    </html>
  );
}
