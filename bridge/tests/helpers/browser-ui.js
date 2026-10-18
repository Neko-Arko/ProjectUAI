'use strict';

// Follow the actual drawer/disclosure controls so navigation coverage works with
// the quiet, initially closed desktop shell as well as the mobile drawer.
function navigation(page) {
  const openSidebar = async () => {
    // A previous click can already be finishing the close animation.
    if (await page.locator('#modal').evaluate(node => node.open && !node.classList.contains('closing'))) await page.locator('#modalClose').click();
    await page.locator('#modal').waitFor({ state: 'hidden' });
    if (await page.locator('#workspaceModal').evaluate(node => node.open && !node.classList.contains('closing'))) await page.locator('#workspaceClose').click();
    await page.locator('#workspaceModal').waitFor({ state: 'hidden' });
    // A resize can resolve before syncSidebar updates aria-expanded.
    await page.waitForFunction(() => {
      const open = innerWidth <= 768 ? document.body.classList.contains('sidebar-open') : !document.body.classList.contains('sidebar-hidden');
      return document.querySelector('#sidebarToggle').getAttribute('aria-expanded') === String(open);
    });
    if (await page.locator('#sidebarToggle').getAttribute('aria-expanded') !== 'true') await page.locator('#sidebarToggle').click();
  };
  const openWorkspace = async () => {
    await openSidebar();
    if (!await page.locator('.more-nav').evaluate(node => node.open)) await page.locator('.more-nav summary').click();
  };
  const navigate = async name => {
    await openSidebar();
    const target = page.locator(`#sidebar [data-page="${name}"]`).first();
    if (await target.evaluate(node => !!node.closest('.more-nav'))) await openWorkspace();
    await target.click();
  };
  return { openSidebar, openWorkspace, navigate };
}

module.exports = { navigation };
