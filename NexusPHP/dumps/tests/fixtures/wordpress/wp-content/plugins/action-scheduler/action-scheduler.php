<?php

declare(strict_types=1);

// The parts of Action Scheduler that Nexus uses, with the same hooks in the same order.

final class ActionScheduler_Action
{
    public function __construct(private readonly string $hook, private readonly array $args, private readonly string $group)
    {
    }

    public function get_hook(): string
    {
        return $this->hook;
    }

    public function get_group(): string
    {
        return $this->group;
    }

    public function execute(): void
    {
        do_action_ref_array($this->hook, $this->args);
    }
}

final class ActionScheduler_Store
{
    private array $actions = [];

    private int $lastId = 41;

    public function save_action(ActionScheduler_Action $action): int
    {
        $id = ++$this->lastId;
        $this->actions[$id] = $action;

        $GLOBALS['wpdb']->query("INSERT INTO wp_actionscheduler_actions (hook) VALUES ('{$action->get_hook()}')");
        do_action('action_scheduler_stored_action', $id);

        return $id;
    }

    public function fetch_action(int|string $id): ActionScheduler_Action
    {
        $GLOBALS['wpdb']->query("SELECT * FROM wp_actionscheduler_actions WHERE action_id = {$id}");

        return $this->actions[(int) $id];
    }
}

final class ActionScheduler
{
    private static ?ActionScheduler_Store $store = null;

    public static function store(): ActionScheduler_Store
    {
        return self::$store ??= new ActionScheduler_Store();
    }
}

function as_enqueue_async_action(string $hook, array $args = [], string $group = ''): int
{
    return ActionScheduler::store()->save_action(new ActionScheduler_Action($hook, $args, $group));
}

function as_process_action(int $id, string $context): void
{
    try {
        do_action('action_scheduler_begin_execute', $id, $context);
        $action = ActionScheduler::store()->fetch_action($id);
        $action->execute();
        do_action('action_scheduler_after_execute', $id, $action, $context);
    } catch (Exception $exception) {
        do_action('action_scheduler_failed_execution', $id, $exception, $context);
    }
}

add_action('action_scheduler_run_queue', static function (string $context): void {
    $ids = [as_enqueue_async_action('shop_send_mail', [], 'shop'), as_enqueue_async_action('shop_fail', [], 'shop')];

    foreach ($ids as $id) {
        as_process_action($id, $context);
    }
});
