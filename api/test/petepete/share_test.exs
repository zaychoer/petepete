defmodule Petepete.ShareTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Share

  # 2026-10-10 is a Saturday; 02:00 UTC is 09:00 WIB, the same day.
  @starts_at ~U[2026-10-10 02:00:00Z]

  defp issued_session do
    group = group_fixture(%{name: "Futsal Kamis"})
    event = event_fixture(group, %{name: "Futsal Kamis Malam"})
    session = session_fixture(event, starts_at: @starts_at, status: "issued")
    cost_item_fixture(session, amount: 100_000, paid_by: member_fixture(group, role: "host"))
    %{group: group, session: session}
  end

  defp bill_for(ctx, attrs) do
    {phone, attrs} = Map.pop(attrs, :phone)
    {name, attrs} = Map.pop(attrs, :name, "Andi")
    member = member_fixture(ctx.group, role: "member")

    member =
      member |> Ecto.Changeset.change(phone: phone, display_name: name) |> Repo.update!()

    bill =
      bill_fixture(ctx.session, member, Map.merge(%{share: 34_000, amount_due: 34_000}, attrs))

    {bill, member}
  end

  describe "wa_me_url/2" do
    test "percent-encodes the text so it decodes back unchanged" do
      text = "Halo Andi!\nTagihan Rp34.000 & 50% off? Bayar: https://x.test/pay/a-b_c?x=1+2#f é 🙏"
      url = Share.wa_me_url("6281234567890", text)

      assert "https://wa.me/6281234567890?text=" <> encoded = url
      refute encoded =~ ~r/[\s&#+?\n]/
      assert URI.decode(encoded) == text
      assert %URI{query: "text=" <> _} = URI.parse(url)
      assert URI.decode_query(URI.parse(url).query) == %{"text" => text}
    end

    test "keeps only the digits of the number; no number opens the chat picker" do
      assert Share.wa_me_url("+62 812-3456-7890", "hi") == "https://wa.me/6281234567890?text=hi"
      assert Share.wa_me_url(nil, "hi yo") == "https://wa.me/?text=hi%20yo"
      assert Share.wa_me_url("", "x") == "https://wa.me/?text=x"
    end
  end

  describe "bills/1" do
    test "an unpaid bill's text has the group, date, amount and pay link" do
      ctx = issued_session()
      {bill, member} = bill_for(ctx, %{phone: "6281234567890"})

      assert {:ok, %{session_id: id, bills: [entry]}} = Share.bills(ctx.session.id)
      assert id == ctx.session.id
      assert entry.bill_id == bill.id
      assert entry.member_id == member.id
      assert entry.has_phone
      assert entry.wa_number == "6281234567890"
      assert entry.pay_url == "https://petepete.test/pay/#{bill.pay_token}"
      assert entry.text =~ "Andi"
      assert entry.text =~ "Futsal Kamis"
      assert entry.text =~ "Sabtu, 10 Okt 2026"
      assert entry.text =~ "Rp34.000"
      assert entry.text =~ entry.pay_url

      assert URI.decode(String.replace_prefix(entry.share_url, "https://wa.me/?text=", "")) ==
               entry.text

      refute entry.share_url =~ "6281234567890"
    end

    test "a member without a phone has no wa_number" do
      ctx = issued_session()
      bill_for(ctx, %{})

      assert {:ok, %{bills: [%{has_phone: false, wa_number: nil}]}} = Share.bills(ctx.session.id)
    end

    test "a paid bill has no pay link; a void one is skipped" do
      ctx = issued_session()
      {paid, _} = bill_for(ctx, %{name: "Budi", status: "paid", paid_via: "cash"})
      {_, _} = bill_for(ctx, %{name: "Citra", status: "void"})

      {credit, _} =
        bill_for(ctx, %{name: "Dewi", status: "paid", paid_via: "credit", amount_due: 0})

      assert {:ok, %{bills: [budi, dewi]}} = Share.bills(ctx.session.id)
      assert budi.bill_id == paid.id and dewi.bill_id == credit.id
      assert budi.pay_url == nil and budi.text =~ "Lunas" and budi.text =~ "Budi"
      refute budi.text =~ "/pay/"
      assert dewi.text =~ "saldo"
    end

    test "a needs_review bill says so and keeps the link for the status page" do
      ctx = issued_session()
      {bill, _} = bill_for(ctx, %{status: "needs_review"})

      assert {:ok, %{bills: [entry]}} = Share.bills(ctx.session.id)
      assert entry.text =~ "Perlu dicek"
      assert entry.text =~ "/pay/#{bill.pay_token}"
    end

    test "draft and cancelled sessions are not shareable, unknown is not found" do
      group = group_fixture()

      for status <- ~w(draft cancelled) do
        session = session_fixture(event_fixture(group), status: status)

        assert Share.bills(session.id) == {:error, {:conflict, :session_not_issued}}
        assert Share.reminder(session.id) == {:error, {:conflict, :session_not_issued}}
        assert Share.summary(session.id) == {:error, {:conflict, :session_not_issued}}
      end

      assert Share.bills(0) == {:error, :not_found}
    end
  end

  describe "reminder/1" do
    test "lists only unpaid and needs_review bills, with amounts and links" do
      ctx = issued_session()
      {andi, _} = bill_for(ctx, %{name: "Andi", phone: "6281234567890"})
      {budi, _} = bill_for(ctx, %{name: "Budi", amount_due: 17_500, status: "needs_review"})
      {_, _} = bill_for(ctx, %{name: "Citra", status: "paid", paid_via: "cash"})

      assert {:ok, %{count: 2, group_text: text, bills: [a, b], share_url: url}} =
               Share.reminder(ctx.session.id)

      assert text =~ "Andi: Rp34.000"
      assert text =~ "Budi: Rp17.500 (Perlu dicek)"
      refute text =~ "Citra"
      assert text =~ "/pay/#{andi.pay_token}"
      assert text =~ "/pay/#{budi.pay_token}"
      refute text =~ "6281234567890"
      assert url == Share.wa_me_url(nil, text)

      assert a.wa_number == "6281234567890"
      assert a.text =~ "Rp34.000" and a.text =~ "/pay/#{andi.pay_token}"
      assert b.text =~ "Rp17.500"
    end

    test "nobody owing gives no text" do
      ctx = issued_session()
      bill_for(ctx, %{status: "paid", paid_via: "cash"})

      assert {:ok, %{count: 0, group_text: nil, share_url: nil, bills: []}} =
               Share.reminder(ctx.session.id)
    end
  end

  describe "summary/1" do
    test "has per-person status, totals and counts, and no tokens or phones" do
      ctx = issued_session()
      {andi, _} = bill_for(ctx, %{name: "Andi", phone: "6281234567890"})
      {_, _} = bill_for(ctx, %{name: "Budi", status: "paid", paid_via: "cash"})
      {budi2, _} = bill_for(ctx, %{name: "Citra", status: "needs_review"})
      {_, _} = bill_for(ctx, %{name: "Dewi", status: "void"})

      assert {:ok, summary} = Share.summary(ctx.session.id)

      assert %{
               total_cost: 100_000,
               total_billed: 102_000,
               kas_remainder: 2_000,
               paid_count: 1,
               unpaid_count: 2
             } = summary

      text = summary.text
      assert text =~ "Futsal Kamis"
      assert text =~ "Sabtu, 10 Okt 2026"
      assert text =~ "Andi: Rp34.000 (Belum bayar)"
      assert text =~ "Budi: Rp34.000 (Lunas)"
      assert text =~ "Citra: Rp34.000 (Perlu dicek)"
      assert text =~ "Dewi: Rp34.000 (Dibatalkan)"
      assert text =~ "Total biaya: Rp100.000"
      assert text =~ "Total tagihan: Rp102.000"
      assert text =~ "Masuk kas: Rp2.000"
      assert text =~ "Lunas 1 orang, belum lunas 2 orang"

      for secret <- [andi.pay_token, budi2.pay_token, "6281234567890", "/pay/", "petepete.test"] do
        refute text =~ secret
        refute summary.share_url =~ secret
      end

      refute inspect(summary) =~ "6281234567890"
    end

    test "a void bill of an earlier issue is hidden once the member has a live bill" do
      ctx = issued_session()
      {_, member} = bill_for(ctx, %{name: "Andi", status: "void"})
      bill_fixture(ctx.session, member, %{share: 34_000, amount_due: 34_000})

      assert {:ok, %{text: text, total_billed: 34_000}} = Share.summary(ctx.session.id)
      assert text =~ "Andi: Rp34.000 (Belum bayar)"
      refute text =~ "Dibatalkan"
    end
  end
end
