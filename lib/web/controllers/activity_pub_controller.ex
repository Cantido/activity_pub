defmodule ActivityPub.Web.ActivityPubController do
  @moduledoc """

  Endpoints for serving objects and collections, so the ActivityPub API can be used to read information from the server.

  Even though we store the data in AS format, some changes need to be applied to the entity before serving it in the AP REST response. This is done in `ActivityPub.Web.ActivityPubView`.
  """

  use ActivityPub.Web, :controller

  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Instances
  alias ActivityPub.Safety.Containment

  alias ActivityPub.Web.ActorView
  alias ActivityPub.Federator
  alias ActivityPub.Web.ObjectView
  # alias ActivityPub.Web.RedirectController

  def ap_route_helper(uuid) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    "#{ActivityPub.Web.base_url()}#{ap_base_path}/objects/#{uuid}"
  end

  def object(conn, %{"uuid" => uuid}) do
    if get_format(conn) == "html" do
      case Adapter.get_redirect_url(uuid) do
        "http" <> _ = url -> redirect(conn, external: url)
        url when is_binary(url) -> redirect(conn, to: url)
        _ -> json_object_with_cache(conn, uuid)
      end
    else
      json_object_with_cache(conn, uuid)
    end
  end

  def json_object_with_cache(conn \\ nil, id)

  def json_object_with_cache(conn_or_nil, id) do
    Utils.json_with_cache(conn_or_nil, &object_json/1, :ap_object_cache, id)
  end

  defp object_json(json: id) do
    if Utils.is_ulid?(id) do
      # querying by pointer - handle local objects
      #  true <- object.id != id, # huh?
      #  current_user <- Map.get(conn.assigns, :current_user, nil) |> debug("current_user"), # TODO: should/how users make authenticated requested?
      # || Containment.visible_for_user?(object, current_user)) |> debug("public or visible for current_user?") 
      maybe_object_json(Object.get_cached!(pointer: id) || Adapter.maybe_publish_object(id))
    else
      # query by UUID

      maybe_object_json(Object.get_cached!(ap_id: ap_route_helper(id)))
    end
  end

  defp maybe_object_json(%{public: true} = object) do
    {:ok,
     %{
       json: ObjectView.render("object.json", %{object: object}),
       meta: %{updated_at: object.updated_at}
     }}
  end

  defp maybe_object_json({:ok, object}) do
    maybe_object_json(object)
  end

  defp maybe_object_json(%Object{}) do
    warn(
      "someone attempted to fetch a non-public object, we acknowledge its existence but do not return it"
    )

    {:error, 401, "authentication required"}
  end

  defp maybe_object_json(other) do
    debug(other, "Pointable not found")
    {:error, 404, "not found"}
  end

  def actor(conn, %{"username" => username}) do
    if get_format(conn) == "html" do
      case Adapter.get_redirect_url(username) do
        "http" <> _ = url -> redirect(conn, external: url)
        url when is_binary(url) -> redirect(conn, to: url)
        _ -> actor_with_cache(conn, username)
      end
    else
      actor_with_cache(conn, username)
    end
  end

  defp actor_with_cache(conn, username) do
    Utils.json_with_cache(conn, &actor_json/1, :ap_actor_cache, username)
  end

  defp actor_json(json: username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      {:ok,
       %{
         json: ActorView.render("actor.json", %{actor: actor}),
         meta: %{updated_at: actor.updated_at}
       }}
    else
      _ ->
        {:error, 404, "not found"}
    end
  end

  def following(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor, page: page_number(page)})
    end
  end

  def following(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor})
    end
  end

  def followers(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor, page: page_number(page)})
    end
  end

  def followers(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor})
    end
  end

  def outbox(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor, page: page_number(page)})
    else
      e ->
        Utils.error_json(conn, "Invalid actor", 500)
    end
  end

  def outbox(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor})
    end
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    process_incoming(conn, params)
  end

  # accept (but verify) unsigned Creates
  # def inbox(conn, %{"type" => "Create"} = params) do
  #   maybe_process_unsigned(conn, params)
  # end

  def inbox(conn, params) do
    maybe_process_unsigned(conn, params)
  end

  def noop(conn, _params) do
    json(conn, "ok")
  end

  defp maybe_process_unsigned(conn, params) do
    if Config.federating?() do
      headers = Enum.into(conn.req_headers, %{})

      if is_binary(headers["signature"]) do
        if String.contains?(headers["signature"], params["actor"]) do
          error(
            headers,
            "Unknown HTTP signature validation error, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
          )
        else
          error(
            headers,
            "No match between actor (#{params["actor"]}) and the HTTP signature provided, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
          )
        end
      else
        error(
          params,
          "No HTTP signature provided, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
        )
      end

      with {:ok, object} <-
             Fetcher.fetch_object_from_id(params["id"]) do
        debug(object, "unsigned activity workaround worked")

        # Utils.error_json(
        #   conn,
        #   "please send signed activities - object was not accepted as-in and instead re-fetched from origin",
        #   202
        # )
        json(
          conn,
          "Please send signed activities - object was not accepted as-in and instead re-fetched from origin"
        )
      else
        e ->
          if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
            warn(
              e,
              "Unsigned incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication. Accept anyway because ACCEPT_UNSIGNED_ACTIVITIES is set in env."
            )

            process_incoming(conn, params)
          else
            error(
              e,
              "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication."
            )

            Utils.error_json(conn, "please send signed activities - activity was rejected", 401)
          end
      end
    else
      Utils.error_json(conn, "This instance is not currently federating", 403)
    end
  end

  defp process_incoming(conn, params) do
    Logger.metadata(action: info("incoming_ap_doc"))

    if Config.federating?() do
      Federator.incoming_ap_doc(params)
      |> info("processed")

      Instances.set_reachable(params["actor"])

      json(conn, "ok")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp page_number("true"), do: 1
  defp page_number(page) when is_binary(page), do: Integer.parse(page) |> elem(0)
  defp page_number(_), do: 1
end
