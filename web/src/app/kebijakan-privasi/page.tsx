import type { Metadata } from "next";
import { LegalPage, Section } from "../legal";

export const metadata: Metadata = {
  title: "Kebijakan Privasi – Petepete",
};

export default function KebijakanPrivasi() {
  return (
    <LegalPage title="Kebijakan Privasi">
      <p>
        Petepete bantu grup olahraga patungan tanpa ribet. Halaman ini jelasin
        data apa yang kami simpan dan hak kamu atas data itu.
      </p>
      <Section title="Data yang kami simpan">
        <ul className="list-disc pl-6">
          <li>Nomor HP dan nama tampilan kamu.</li>
          <li>
            Catatan grup, sesi, tagihan, dan buku kas (ledger) yang kamu ikuti.
          </li>
        </ul>
        <p>
          Kami tidak menyimpan data kartu. Data pembayaran dipegang oleh payment
          gateway, bukan oleh Petepete.
        </p>
      </Section>
      <Section title="Saldo bukan dana tersimpan">
        <p>
          Saldo dan kredit di Petepete cuma catatan pembukuan. Petepete tidak
          menampung dana siapa pun.
        </p>
      </Section>
      <Section title="Hapus akun">
        <p>
          Kamu bisa hapus akun kapan saja lewat menu Hapus akun di aplikasi.
          Nama dan nomor kamu akan dianonimkan. Entri buku kas tetap disimpan
          supaya hitungan grup tetap benar, dengan label &quot;Mantan
          anggota&quot;. Akun host yang masih memegang grup aktif harus
          diserahkan atau ditutup dulu sebelum bisa dihapus.
        </p>
      </Section>
    </LegalPage>
  );
}
