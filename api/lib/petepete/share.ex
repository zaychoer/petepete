defmodule Petepete.Share do
  @moduledoc """
  "Bagikan ke WA": the texts the host sends about an issued Session through WhatsApp.

  The server only builds text. The host's app or web opens `wa_me_url/2` on the host's
  own device; there is no WhatsApp API and nothing is delivered from the server.

  Three texts, all Indonesian casual, amounts as `Rp45.000`
  (`Petepete.Ledger.Description.rupiah/1`), date as the session's WIB date:

    * `bills/1`: one personal message per live Bill (plus a text-less `void` entry for a
      Member whose only Bill was voided, so the host's status screen is never blank). Unpaid and needs_review Bills carry
      the pay link `<web_base_url>/pay/<pay_token>`. A Member with a phone gets it as
      `wa_number` (digits only, e.g. `6281234567890`) so the host's app can open a personal
      wa.me link; everyone else only gets `has_phone: false`. Host only: it holds pay tokens
      and phone numbers.
    * `reminder/1`: one group message listing who has not paid yet (unpaid and needs_review
      Bills, with links) plus the same per-person messages in a reminder tone. Host only.
    * `summary/1`: a plain-text recap safe to paste into the group chat. It has per-person
      amounts and status text (Lunas, Belum bayar, Perlu dicek, Dibatalkan), total cost,
      total billed, "Masuk kas" and paid vs unpaid counts, and NO pay tokens, NO phone
      numbers and no pay links.

  A Member's phone number leaves this module only as `wa_number` in `bills/1` and
  `reminder/1`; nothing here logs.

  Only issued sessions can be shared: a draft or cancelled one is
  `{:error, {:conflict, :session_not_issued}}`. Authorization is the caller's job
  (`PetepeteWeb.Plugs.SessionAccess`).
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, CostItem, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Ledger.Description
  alias Petepete.{Clock, Ledger, Repo, Wib}
  alias PetepeteWeb.Labels

  @days ~w(Senin Selasa Rabu Kamis Jumat Sabtu Minggu)
  @months ~w(Jan Feb Mar Apr Mei Jun Jul Agu Sep Okt Nov Des)

  @type entry :: %{
          bill_id: pos_integer(),
          member_id: pos_integer(),
          display_name: String.t(),
          status: String.t(),
          amount_due: integer(),
          paid_via: String.t() | nil,
          paid_at: DateTime.t() | nil,
          cash_cancellable: boolean(),
          has_phone: boolean(),
          wa_number: String.t() | nil,
          pay_url: String.t() | nil,
          token_expires_at: DateTime.t() | nil,
          text: String.t() | nil,
          share_url: String.t() | nil
        }

  @type error :: :not_found | {:conflict, :session_not_issued}

  @doc """
  `https://wa.me/<digits>?text=<percent-encoded text>`, or `https://wa.me/?text=...` (the
  chat picker) when `number` is `nil` or has no digits. Any non-digit in `number` (`+`,
  spaces, dashes) is dropped. The text is encoded as UTF-8 with everything outside the
  RFC 3986 unreserved set escaped, so spaces are `%20` and newlines `%0A`.
  """
  @spec wa_me_url(String.t() | nil, String.t()) :: String.t()
  def wa_me_url(number, text) when is_binary(text) do
    "https://wa.me/" <> digits(number) <> "?text=" <> URI.encode(text, &URI.char_unreserved?/1)
  end

  @doc """
  Personal bill messages of an issued session, one per live Bill, ordered by bill id:
  `{:ok, %{session_id: id, bills: [entry]}}`. A Member who only has void Bills (an earlier
  issue was voided) appears once with `status: "void"`, no `text`, `share_url` or `pay_url`,
  so a session whose Bills were all voided is still listed; no message is generated for
  void Bills.

  Each `entry` has `bill_id`, `member_id`, `display_name`, `status`, `amount_due`,
  `paid_via` (`cash`, `gateway`, `credit` or `nil`), `paid_at`, `cash_cancellable` (a cash
  payment still inside the Ledger's 24 hour undo window; the Ledger decides on the actual
  cancel), `has_phone`, `wa_number` (digits or `nil`), `pay_url` (`nil` once paid),
  `token_expires_at`, `text` and `share_url` (a number-less `wa_me_url/2` of `text`, for
  picking the chat).
  """
  @spec bills(pos_integer()) ::
          {:ok, %{session_id: pos_integer(), bills: [entry()]}} | {:error, error()}
  def bills(session_id) do
    with {:ok, ctx} <- load(session_id) do
      rows = Enum.sort_by(summary_rows(ctx), fn {bill, _} -> bill.id end)
      {:ok, %{session_id: session_id, bills: Enum.map(rows, &entry(ctx, &1, :bill))}}
    end
  end

  @doc """
  The reminder for everyone who still owes: `{:ok, %{session_id:, count:, group_text:,
  bills: [entry]}}` over the unpaid and needs_review Bills. `group_text` is one message
  for the group chat (names, amounts and links) and `share_url` its number-less wa.me
  link; both are `nil` when nobody owes. `bills` are the personal reminders, same shape
  as `bills/1`.
  """
  @spec reminder(pos_integer()) ::
          {:ok,
           %{
             session_id: pos_integer(),
             count: non_neg_integer(),
             group_text: String.t() | nil,
             share_url: String.t() | nil,
             bills: [entry()]
           }}
          | {:error, error()}
  def reminder(session_id) do
    with {:ok, ctx} <- load(session_id) do
      owing = Enum.filter(live(ctx), fn {bill, _} -> bill.status in ~w(unpaid needs_review) end)
      group_text = if owing != [], do: reminder_group_text(ctx, owing)

      {:ok,
       %{
         session_id: session_id,
         count: length(owing),
         group_text: group_text,
         share_url: group_text && wa_me_url(nil, group_text),
         bills: Enum.map(owing, &entry(ctx, &1, :reminder))
       }}
    end
  end

  @doc """
  The recap to paste into the group: `{:ok, summary}` with `session_id`, `text`,
  `share_url`, `total_cost`, `total_billed`, `kas_remainder` ("Masuk kas"), `paid_count`
  and `unpaid_count` (unpaid plus needs_review). Void Bills of an earlier issue only show
  for a member without a live Bill, as Dibatalkan, and count nowhere.
  """
  @spec summary(pos_integer()) :: {:ok, map()} | {:error, error()}
  def summary(session_id) do
    with {:ok, ctx} <- load(session_id) do
      live = live(ctx)
      total_cost = ctx.costs
      total_billed = live |> Enum.map(fn {bill, _} -> bill.share end) |> Enum.sum()
      paid = Enum.count(live, fn {bill, _} -> bill.status == "paid" end)
      unpaid = length(live) - paid
      kas = total_billed - total_cost

      text =
        [
          "Ringkasan #{title(ctx)}",
          date_text(ctx.session),
          "",
          "Tagihan per orang:"
        ]
        |> Kernel.++(for {bill, member} <- summary_rows(ctx), do: summary_line(bill, member))
        |> Kernel.++([
          "",
          "Total biaya: #{rupiah(total_cost)}",
          "Total tagihan: #{rupiah(total_billed)}",
          "Masuk kas: #{rupiah(kas)}",
          "Lunas #{paid} orang, belum lunas #{unpaid} orang"
        ])
        |> Enum.join("\n")

      {:ok,
       %{
         session_id: session_id,
         text: text,
         share_url: wa_me_url(nil, text),
         total_cost: total_cost,
         total_billed: total_billed,
         kas_remainder: kas,
         paid_count: paid,
         unpaid_count: unpaid
       }}
    end
  end

  ## Texts

  defp entry(ctx, {bill, member}, kind) do
    number = digits(member.phone)
    text = if bill.status != "void", do: message(ctx, bill, member, kind)

    %{
      bill_id: bill.id,
      member_id: member.id,
      display_name: member.display_name,
      status: bill.status,
      status_label: Labels.bill(bill.status),
      amount_due: bill.amount_due,
      paid_via: bill.paid_via,
      paid_via_label: Labels.paid_via(bill.paid_via),
      paid_at: bill.paid_at,
      cash_cancellable: cash_cancellable?(bill),
      has_phone: number != "",
      wa_number: if(number != "", do: number),
      pay_url: if(bill.status not in ~w(paid void), do: pay_url(bill)),
      token_expires_at: bill.token_expires_at,
      text: text,
      share_url: text && wa_me_url(nil, text)
    }
  end

  defp cash_cancellable?(%Bill{status: "paid", paid_via: "cash", paid_at: %DateTime{} = at}),
    do: Ledger.cash_undo_window_open?(at, Clock.now())

  defp cash_cancellable?(_bill), do: false

  defp message(ctx, %Bill{status: "paid"} = bill, member, _kind) do
    """
    Halo #{member.display_name}! Tagihan #{title(ctx)} (#{date_text(ctx.session)}) sudah Lunas#{paid_note(bill)}. Makasih ya!\
    """
  end

  defp message(ctx, %Bill{status: "needs_review"} = bill, member, _kind) do
    """
    Halo #{member.display_name}! Pembayaran #{rupiah(bill.amount_due)} untuk #{title(ctx)} (#{date_text(ctx.session)}) lagi Perlu dicek host, nominalnya belum cocok.
    Cek statusnya di sini: #{pay_url(bill)}\
    """
  end

  defp message(ctx, %Bill{} = bill, member, :bill) do
    """
    Halo #{member.display_name}! Tagihan #{title(ctx)} (#{date_text(ctx.session)}): #{rupiah(bill.amount_due)}.
    Bayar lewat link ini ya: #{pay_url(bill)}
    Makasih!\
    """
  end

  defp message(ctx, %Bill{} = bill, member, :reminder) do
    """
    Halo #{member.display_name}, mau ngingetin tagihan #{title(ctx)} (#{date_text(ctx.session)}) #{rupiah(bill.amount_due)} belum masuk nih.
    Bayar lewat link ini ya: #{pay_url(bill)}
    Makasih!\
    """
  end

  defp paid_note(%Bill{amount_due: 0}), do: " (sudah ketutup pakai saldo kamu)"
  defp paid_note(_), do: ""

  defp reminder_group_text(ctx, owing) do
    lines =
      for {bill, member} <- owing do
        flag = if bill.status == "needs_review", do: " (Perlu dicek)", else: ""
        "- #{member.display_name}: #{rupiah(bill.amount_due)}#{flag}\n  #{pay_url(bill)}"
      end

    Enum.join(
      [
        "Halo semua! Pengingat tagihan #{title(ctx)} (#{date_text(ctx.session)}). Yang belum bayar:",
        "" | lines
      ] ++ ["", "Yuk bayar lewat link masing-masing. Makasih!"],
      "\n"
    )
  end

  defp summary_rows(ctx) do
    live_members = MapSet.new(live(ctx), fn {_bill, member} -> member.id end)

    voids =
      for {%Bill{status: "void"}, member} = row <- ctx.rows,
          not MapSet.member?(live_members, member.id),
          do: row

    live(ctx) ++ Enum.uniq_by(voids, fn {_bill, member} -> member.id end)
  end

  defp summary_line(bill, member),
    do: "- #{member.display_name}: #{rupiah(bill.share)} (#{Labels.bill(bill.status)})"

  defp title(%{group: group, event: event}) do
    if event.name in [nil, "", group.name],
      do: group.name,
      else: "#{event.name} (#{group.name})"
  end

  defp date_text(%Session{starts_at: starts_at}) do
    date = Wib.date(starts_at)
    day = Enum.at(@days, Date.day_of_week(date) - 1)
    "#{day}, #{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end

  defp rupiah(amount), do: Description.rupiah(amount)

  defp pay_url(%Bill{pay_token: token}) do
    base = :petepete |> Application.fetch_env!(:web_base_url) |> String.trim_trailing("/")
    "#{base}/pay/#{token}"
  end

  defp digits(nil), do: ""
  defp digits(number) when is_binary(number), do: String.replace(number, ~r/\D/, "")

  ## Loading

  defp live(ctx), do: Enum.reject(ctx.rows, fn {bill, _} -> bill.status == "void" end)

  defp load(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{status: "issued"} = session ->
        {:ok,
         %{
           session: session,
           group: Repo.get!(Group, session.group_id),
           event: Repo.preload(session, :event).event,
           rows: rows(session_id),
           costs: costs(session_id)
         }}

      %Session{} ->
        {:error, {:conflict, :session_not_issued}}
    end
  end

  defp rows(session_id) do
    Repo.all(
      from b in Bill,
        join: m in Member,
        on: m.id == b.member_id,
        where: b.session_id == ^session_id,
        order_by: b.id,
        select: {b, m}
    )
  end

  defp costs(session_id) do
    Repo.one(from c in CostItem, where: c.session_id == ^session_id, select: sum(c.amount))
    |> case do
      nil -> 0
      total -> Decimal.to_integer(total)
    end
  end
end
