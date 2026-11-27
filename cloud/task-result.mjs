export function hydrateCloudTask(store,accountId,task) {
  const links=store.list(accountId,'task_tag').filter(link=>link.task_id===task.id);
  const tagIds=new Set(links.map(link=>link.tag_id));
  const tags=store.list(accountId,'tag').filter(tag=>tagIds.has(tag.id)).map(tag=>tag.display_name);
  const depends_on=store.list(accountId,'task_dependency')
    .filter(edge=>edge.task_id===task.id).map(edge=>edge.depends_on_task_id);
  return {...task,tags,depends_on};
}
