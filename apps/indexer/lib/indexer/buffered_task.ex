defmodule Indexer.BufferedTask do
  @moduledoc """
  Provides a behaviour for batched task running with retries.

  ## Named Arguments

  Named arguments are required and are passed in the list that is the second element of the tuple.

    * `:flush_interval` - The interval in milliseconds to flush the buffer.
    * `:max_concurrency` - The maximum number of tasks to run concurrently at any give time.
    * `:max_batch_size` - The maximum batch passed to `c:run/2`.
    * `:init_chunk_size` - The chunk size to chunk `c:init/2` entries for initial buffer population.
    * `:task_supervisor` - The `Task.Supervisor` name to spawn tasks under.

  ## Options

  Options are optional and are passed in the list that is second element of the tuple.

    * `:name` - The registred name for the new process.

  ## Callbacks

  `c:init/2` is used for a task to populate its buffer on boot with an initial set of entries.

  For example, the following callback would buffer all unfetched account balances on startup:

      def init(initial, reducer) do
        Chain.stream_unfetched_balances([:hash], initial, fn %{hash: hash}, acc ->
          reducer.(Hash.to_string(hash), acc)
        end)
      end

  `c:init/2` may be long-running and allows concurrent calls to `Explorer.BufferedTask.buffer/2` for on-demand entries.
  As concurrency becomes available, `c:run/2` of the task is invoked, with a list of batched entries to be processed.

  For example, the `c:run/2` for above `c:init/2` could be written:

      def run(string_hashes, _retries) do
        case EthereumJSONRPC.fetch_balances_by_hash(string_hashes) do
          {:ok, results} -> :ok = update_balances(results)
          {:error, _reason} -> :retry
        end
      end

  If a task crashes, it will be retried automatically with an increased `retries` count passed in as the second
  argument. Tasks may also be programmatically retried by returning `:retry` from `c:run/2`.
  """

  use GenServer

  require Logger

  alias Indexer.BufferedTask

  @enforce_keys [
    :pid,
    :callback_module,
    :callback_module_state,
    :task_supervisor,
    :flush_interval,
    :max_batch_size,
    :init_chunk_size
  ]
  defstruct pid: nil,
            init_task: nil,
            flush_timer: nil,
            callback_module: nil,
            callback_module_state: nil,
            task_supervisor: nil,
            flush_interval: nil,
            max_batch_size: nil,
            max_concurrency: nil,
            init_chunk_size: nil,
            current_buffer: [],
            buffer: :queue.new(),
            tasks: %{}

  @typedoc """
  Entry passed to `t:reducer/2` in `c:init/2` and grouped together into a list as `t:entries/0` passed to `c:run/2`.
  """
  @type entry :: term()

  @typedoc """
  List of `t:entry/0` passed to `c:run/2`.
  """
  @type entries :: [entry, ...]

  @typedoc """
  The initial `t:accumulator/0` for `c:init/2`.
  """
  @opaque initial :: {0, []}

  @typedoc """
  The accumulator passed through the `t:reducer/0` for `c:init/2`.
  """
  @opaque accumulator :: {non_neg_integer(), list()}

  @typedoc """
  Reducer for `c:init/2`.

  Accepts entry generated by callback module and passes through `accumulator`.  `Explorer.BufferTask` itself will decide
  how to integrate `entry` into `accumulator` or to run `c:run/2`.
  """
  @type reducer :: (entry, accumulator -> accumulator)

  @typedoc """
  Callback module controlled state.  Can be used to store extra information needed for each `run/2`
  """
  @type state :: term()

  @doc """
  Populates a task's buffer on boot with an initial set of entries.

  For example, the following callback would buffer all unfetched account balances on startup:

      def init(initial, reducer, state) do
        final = Chain.stream_unfetched_balances([:hash], initial, fn %{hash: hash}, acc ->
          reducer.(Hash.to_string(hash), acc)
        end)

        {final, state}
      end

  The `init/2` operation may be long-running as it is run in a separate process and allows concurrent calls to
  `Explorer.BufferedTask.buffer/2` for on-demand entries.
  """
  @callback init(initial, reducer, state) :: accumulator

  @doc """
  Invoked as concurrency becomes available with a list of batched entries to be processed.

  For example, the `c:run/2` callback for the example `c:init/2` callback could be written:

      def run(string_hashes, _retries) do
        case EthereumJSONRPC.fetch_balances_by_hash(string_hashes) do
          {:ok, results} -> :ok = update_balances(results)
          {:error, _reason} -> :retry
        end
      end

  If a task crashes, it will be retried automatically with an increased `retries` count passed in as the second
  argument. Tasks may also be programmatically retried by returning `:retry` from `c:run/2`.

  ## Returns

   * `:ok` - run was successful
   * `:retry` - run should be retried after it failed
   * `{:retry, new_entries :: list}` - run should be retried with `new_entries`

  """
  @callback run(entries, retries :: pos_integer, state) :: :ok | :retry | {:retry, new_entries :: list}

  @doc """
  Buffers list of entries for future async execution.
  """
  @spec buffer(GenServer.name(), entries(), timeout()) :: :ok
  def buffer(server, entries, timeout \\ 5000) when is_list(entries) do
    GenServer.call(server, {:buffer, entries}, timeout)
  end

  def child_spec([init_arguments]) do
    child_spec([init_arguments, []])
  end

  def child_spec([_init_arguments, _gen_server_options] = start_link_arguments) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments}
    }

    Supervisor.child_spec(default, [])
  end

  @doc false
  def debug_count(server) do
    GenServer.call(server, :debug_count)
  end

  @doc """
  Starts `callback_module` as a buffered task.

  Takes a tuple of the callback module and list of named arguments and options, much like the format accepted for
  `Supervisor.start_link/2`, `Supervisor.init/2` and `Supervisor.child_spec/2`.

  ## Named Arguments

  Named arguments are required and are passed in the list that is the second element of the tuple.

    * `:flush_interval` - The interval in milliseconds to flush the buffer.
    * `:max_concurrency` - The maximum number of tasks to run concurrently at any give time.
    * `:max_batch_size` - The maximum batch passed to `c:run/2`.
    * `:init_chunk_size` - The chunk size to chunk `c:init/2` entries for initial buffer population.
    * `:task_supervisor` - The `Task.Supervisor` name to spawn tasks under.

  ## Options

  Options are optional and are passed in the list that is second element of the tuple.

    * `:name` - The registred name for the new process.

  """
  @spec start_link(
          {callback_module :: module,
           [
             {:flush_interval, timeout()}
             | {:init_chunk_size, pos_integer()}
             | {:max_batch_size, pos_integer()}
             | {:max_concurrency, pos_integer()}
             | {:name, GenServer.name()}
             | {:task_supervisor, GenServer.name()}
             | {:state, state}
           ]}
        ) :: {:ok, pid()} | {:error, {:already_started, pid()}}
  def start_link({module, base_init_opts}, genserver_opts \\ []) do
    default_opts = Application.get_all_env(:indexer)
    init_opts = Keyword.merge(default_opts, base_init_opts)

    GenServer.start_link(__MODULE__, {module, init_opts}, genserver_opts)
  end

  def init({callback_module, opts}) do
    send(self(), :initial_stream)

    state = %BufferedTask{
      pid: self(),
      callback_module: callback_module,
      callback_module_state: Keyword.fetch!(opts, :state),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      flush_interval: Keyword.fetch!(opts, :flush_interval),
      max_batch_size: Keyword.fetch!(opts, :max_batch_size),
      max_concurrency: Keyword.fetch!(opts, :max_concurrency),
      init_chunk_size: Keyword.fetch!(opts, :init_chunk_size)
    }

    {:ok, state}
  end

  def handle_info(:initial_stream, state) do
    {:noreply, do_initial_stream(state)}
  end

  def handle_info(:flush, state) do
    {:noreply, flush(state)}
  end

  def handle_info({ref, :ok}, %{init_task: ref} = state) do
    {:noreply, state}
  end

  def handle_info({ref, :ok}, state) do
    {:noreply, drop_task(state, ref)}
  end

  def handle_info({ref, :retry}, state) do
    {:noreply, drop_task_and_retry(state, ref)}
  end

  def handle_info({ref, {:retry, retryable_entries}}, state) do
    {:noreply, drop_task_and_retry(state, ref, retryable_entries)}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %BufferedTask{init_task: ref} = state) do
    {:noreply, %{state | init_task: :complete}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_task_and_retry(state, ref)}
  end

  def handle_call({:async_perform, stream_que}, _from, state) do
    new_buffer = :queue.join(state.buffer, stream_que)
    {:reply, :ok, spawn_next_batch(%{state | buffer: new_buffer})}
  end

  def handle_call({:buffer, entries}, _from, state) do
    {:reply, :ok, buffer_entries(state, entries)}
  end

  def handle_call(:metrics, _from, state) do
    length = length(state.current_buffer) + :queue.len(state.buffer) * state.max_batch_size

    {:reply, %{buffer_guage: length, task_guage: Enum.count(state.tasks)}, state}
  end

  defp drop_task(state, ref) do
    spawn_next_batch(%BufferedTask{state | tasks: Map.delete(state.tasks, ref)})
  end

  defp drop_task_and_retry(state, ref, new_batch \\ nil) do
    {batch, retries} = Map.fetch!(state.tasks, ref)

    state
    |> drop_task(ref)
    |> queue_in_state(new_batch || batch, retries + 1)
  end

  defp buffer_entries(state, []), do: state

  defp buffer_entries(%__MODULE__{callback_module: callback_module} = state, entries) do
    Telemetry.execute([:indexer, :buffered_task, :current_buffer, :grow], length(entries), %{callback_module: callback_module})

    %{state | current_buffer: [entries | state.current_buffer]}
  end

  defp queue_in_state(%BufferedTask{} = state, batch, retries) do
    %{state | buffer: queue_in_queue(state.buffer, batch, retries)}
  end

  defp queue_in_queue(queue, batch, retries) do
    :queue.in({batch, retries}, queue)
  end

  defp do_initial_stream(
         %BufferedTask{callback_module_state: callback_module_state, init_chunk_size: init_chunk_size} = state
       ) do
    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        {0, []}
        |> state.callback_module.init(
          fn
            entry, {len, acc} when len + 1 >= init_chunk_size ->
              [entry | acc]
              |> chunk_into_queue(state)
              |> async_perform(state.pid)

              {0, []}

            entry, {len, acc} ->
              {len + 1, [entry | acc]}
          end,
          callback_module_state
        )
        |> catchup_remaining(state)
      end)

    schedule_next_buffer_flush(%BufferedTask{state | init_task: task.ref})
  end

  defp catchup_remaining({0, []}, _state), do: :ok

  defp catchup_remaining({len, batch}, state) when is_integer(len) and is_list(batch) do
    batch
    |> chunk_into_queue(state)
    |> async_perform(state.pid)

    :ok
  end

  defp chunk_into_queue(entries, state) do
    entries
    |> Enum.reverse()
    |> Enum.chunk_every(state.max_batch_size)
    |> Enum.reduce(:queue.new(), fn batch, acc -> queue_in_queue(acc, batch, 0) end)
  end

  defp take_batch(state) do
    case :queue.out(state.buffer) do
      {{:value, batch}, new_queue} -> {batch, new_queue}
      {:empty, new_queue} -> {[], new_queue}
    end
  end

  defp async_perform(entries, dest) do
    GenServer.call(dest, {:async_perform, entries})
  end

  defp schedule_next_buffer_flush(state) do
    timer = Process.send_after(self(), :flush, state.flush_interval)
    %{state | flush_timer: timer}
  end

  defp spawn_next_batch(state) do
    if Enum.count(state.tasks) < state.max_concurrency and :queue.len(state.buffer) > 0 do
      {{batch, retries}, new_queue} = take_batch(state)

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, state.callback_module, :run, [
          batch,
          retries,
          state.callback_module_state
        ])

      %{state | tasks: Map.put(state.tasks, task.ref, {batch, retries}), buffer: new_queue}
    else
      state
    end
  end

  defp flush(%BufferedTask{current_buffer: []} = state) do
    state |> spawn_next_batch() |> schedule_next_buffer_flush()
  end

  defp flush(%BufferedTask{callback_module: callback_module, current_buffer: current} = state) do
    Telemetry.execute([:indexer, :buffered_task, :current_buffer, :reset], 0, %{callback_module: callback_module})

    current
    |> List.flatten()
    |> Enum.chunk_every(state.max_batch_size)
    |> Enum.reduce(%{state | current_buffer: []}, fn batch, state_acc ->
      queue_in_state(state_acc, batch, 0)
    end)
    |> flush()
  end
end
