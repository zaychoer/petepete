"use client";

export default function JoinError({ unstable_retry }: { unstable_retry: () => void }) {
  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center gap-3 p-6">
      <h1 className="text-2xl font-semibold">Undangan belum bisa dimuat</h1>
      <p>Koneksi atau server lagi bermasalah. Coba lagi sebentar ya.</p>
      <button
        type="button"
        onClick={() => unstable_retry()}
        className="w-full rounded-lg bg-green-700 px-4 py-3 font-medium text-white"
      >
        Coba lagi
      </button>
    </main>
  );
}
