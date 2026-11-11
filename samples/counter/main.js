/**
 * Hello Counter — minimal ZAgents chat module (sample).
 *
 * Demonstrates: `zagents.storage` (permission `storage`).
 *
 * Every chat session gets its own storage: activating this module in
 * another chat starts from zero again — the private-window guarantee.
 * Docs: docs/modules/sdk-reference-en.md
 */
async function main() {
  const info = zagents.info;
  const previous = (await zagents.storage.get('count')) || 0;
  const current = previous + 1;
  await zagents.storage.set('count', current);

  zagents.log('Module:', info.name, 'v' + info.version);
  zagents.log('Activations in THIS chat:', current);
  zagents.log('Storage keys now:', (await zagents.storage.keys()).join(', '));

  return {
    module: info.name,
    activationsInThisChat: current,
  };
}

module.exports = main();
