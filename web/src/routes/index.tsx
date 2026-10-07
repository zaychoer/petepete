import { Link, createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  component: Home,
});

function Home() {
  return (
    <>
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center gap-2 p-6">
        <h1 className="text-2xl font-semibold">Petepete</h1>
        <p>Buka link tagihan dari host grupmu untuk membayar.</p>
      </main>
      <footer className="mx-auto flex w-full max-w-md gap-4 p-6 text-sm">
        <Link to="/kebijakan-privasi" className="underline">
          Kebijakan Privasi
        </Link>
        <Link to="/syarat-ketentuan" className="underline">
          Syarat &amp; Ketentuan
        </Link>
      </footer>
    </>
  );
}
