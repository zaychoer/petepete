import type { Metadata } from "next";
import { LegalPage, Section } from "../legal";

export const metadata: Metadata = {
  title: "Syarat & Ketentuan – Petepete",
};

export default function SyaratKetentuan() {
  return (
    <LegalPage title="Syarat & Ketentuan">
      <p>
        Dengan memakai Petepete, kamu setuju dengan syarat berikut. Singkat aja
        ya.
      </p>
      <Section title="Apa itu Petepete">
        <p>
          Petepete adalah alat bantu mencatat dan menagih patungan grup
          olahraga. Pembayaran lewat link diproses oleh payment gateway.
        </p>
      </Section>
      <Section title="Saldo bukan dana tersimpan">
        <p>
          Saldo dan kredit adalah catatan pembukuan antaranggota grup, bukan
          uang yang disimpan di Petepete. Petepete tidak menampung dana. Dana
          dari pembayaran lewat gateway diteruskan ke host.
        </p>
      </Section>
      <Section title="Data kamu">
        <p>
          Data apa yang kami simpan dan cara menghapusnya dijelaskan di{" "}
          <a href="/kebijakan-privasi" className="underline">
            Kebijakan Privasi
          </a>
          . Kamu bisa hapus akun lewat Hapus akun di aplikasi; entri buku kas
          tetap ada dengan label &quot;Mantan anggota&quot;.
        </p>
      </Section>
      <Section title="Tanggung jawab">
        <p>
          Host bertanggung jawab atas tagihan yang ia buat. Pastikan catatan
          kehadiran dan biaya sudah benar sebelum menagih.
        </p>
      </Section>
    </LegalPage>
  );
}
