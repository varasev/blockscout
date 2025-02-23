defmodule BlockScoutWeb.Tokens.TransferController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.Tokens.TransferView
  alias Explorer.{Chain, Market}
  alias Phoenix.View

  import BlockScoutWeb.Chain, only: [split_list_by_page: 1, paging_options: 1, next_page_params: 3]
  import BlockScoutWeb.Tokens.TokenController, only: [fetch_token_counters: 2]

  def index(conn, %{"token_id" => address_hash_string, "type" => "JSON"} = params) do
    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {:ok, token} <- Chain.token_from_address_hash(address_hash),
         token_transfers <- Chain.fetch_token_transfers_from_token_hash(address_hash, paging_options(params)) do
      {token_transfers_paginated, next_page} = split_list_by_page(token_transfers)

      next_page_path =
        case next_page_params(next_page, token_transfers_paginated, params) do
          nil ->
            nil

          next_page_params ->
            token_transfer_path(conn, :index, token.contract_address_hash, Map.delete(next_page_params, "type"))
        end

      transfers_json =
        Enum.map(token_transfers_paginated, fn transfer ->
          View.render_to_string(
            TransferView,
            "_token_transfer.html",
            conn: conn,
            token: token,
            token_transfer: transfer
          )
        end)

      json(conn, %{items: transfers_json, next_page_path: next_page_path})
    else
      :error ->
        unprocessable_entity(conn)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def index(conn, %{"token_id" => address_hash_string}) do
    options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]

    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {:ok, token} <- Chain.token_from_address_hash(address_hash, options) do
      {total_token_transfers, total_token_holders} = fetch_token_counters(token, address_hash)

      render(
        conn,
        "index.html",
        current_path: current_path(conn),
        token: Market.add_price(token),
        total_token_transfers: total_token_transfers,
        total_token_holders: total_token_holders
      )
    else
      :error ->
        not_found(conn)

      {:error, :not_found} ->
        not_found(conn)
    end
  end
end
