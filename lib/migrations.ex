defmodule ActivityPub.Migrations do
  @moduledoc false
  use Ecto.Migration

  def weak_pointer() do
    if Code.ensure_loaded?(Pointers.Pointer) do
      references(Pointers.Pointer.__schema__(:source),
        type: :uuid,
        on_update: :update_all,
        on_delete: :nilify_all
      )
    else
      :uuid
    end
  end

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    create table("ap_object", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:data, :map)
      add(:local, :boolean, default: false, null: false)
      add(:public, :boolean, default: false, null: false)
      add(:pointer_id, weak_pointer())

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ap_object, ["(data->>'id')"]))
    create(unique_index(:ap_object, [:pointer_id]))

    create table("ap_instance", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:host, :string)
      add(:unreachable_since, :naive_datetime_usec)

      timestamps()
    end

    create(unique_index("ap_instance", [:host]))
    create(index("ap_instance", [:unreachable_since]))
  end

  def prepare_test do
    # This local_actor table only exists for test purposes
    create_if_not_exists table("local_actor", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:username, :citext)
      add(:data, :map)
      add(:local, :boolean, default: false, null: false)
      add(:keys, :text)
      add(:followers, {:array, :string})
    end
  end

  def down do
    drop(table("ap_object"))
    # drop index(:ap_object, ["(data->>'id')"])
    # drop index(:ap_object, [:pointer_id])
    drop(table("ap_instance"))
    # drop index("ap_instance", [:host])
    # drop index("ap_instance", [:unreachable_since])
  end

  def add_object_boolean do
    alter(table("ap_object")) do
      add(:is_object, :boolean, default: false, null: false)
    end
  end

  def drop_object_boolean do
    alter(table("ap_object")) do
      remove(:is_object)
    end
  end
end
