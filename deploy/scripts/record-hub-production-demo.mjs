import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

const baseURL = (process.env.HUB_VIDEO_BASE_URL ?? 'https://yellow.it.kr').replace(/\/$/, '');
const projectName = process.env.HUB_VIDEO_PROJECT_NAME ?? 'Hub 협업 촬영 데모';
const outDir = process.env.HUB_VIDEO_OUT_DIR ?? 'hub-production-videos';
await mkdir(outDir, { recursive: true });
await mkdir(`${outDir}/raw`, { recursive: true });

const credentials = {
  ADMIN: {
    login: process.env.HUB_VIDEO_ADMIN_LOGIN ?? '',
    password: process.env.HUB_VIDEO_ADMIN_PASSWORD ?? '',
  },
  MEMBER: {
    login: process.env.HUB_VIDEO_MEMBER_LOGIN ?? '',
    password: process.env.HUB_VIDEO_MEMBER_PASSWORD ?? '',
  },
};

for (const [role, value] of Object.entries(credentials)) {
  if (!value.login || !value.password) throw new Error(`${role} filming credentials are missing.`);
}

const ADMIN_ROUTES = [
  '/',
  '/admin/members',
  '/review',
  '/admin/reassign',
  '/todos',
  '/search',
  '/ask',
  '/context',
  '/documents',
  '/meetings',
  '/sheets',
  '/connectors',
  '/account',
  '/admin/users',
  '/admin/organization',
  '/admin/search',
  '/admin/security',
  '/admin/history',
];

const MEMBER_ROUTES = [
  '/',
  '/todos',
  '/search',
  '/ask',
  '/context',
  '/review',
  '/documents',
  '/meetings',
  '/sheets',
  '/connectors',
  '/account',
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function settle(page, ms = 2200) {
  await page.waitForLoadState('domcontentloaded').catch(() => {});
  await sleep(ms);
}

async function selectDemoProject(page) {
  if (await page.getByText(projectName, { exact: true }).count()) return;
  const trigger = page.locator('header button:has(svg.lucide-chevron-down)').first();
  if (!(await trigger.count())) throw new Error('Project selector was not found.');
  await trigger.click();
  await sleep(650);
  const item = page.getByRole('menuitem', { name: projectName, exact: true });
  if (!(await item.count())) throw new Error(`Demo project '${projectName}' was not found.`);
  await item.click();
  await sleep(1800);
}

async function navigateLikeUser(page, path) {
  const current = new URL(page.url()).pathname;
  if (current === path) return;
  await page.keyboard.press('Escape').catch(() => {});
  await sleep(500);
  const link = page.locator(`a[href="${path}"]:visible`).first();
  if (await link.count()) {
    try {
      await link.scrollIntoViewIfNeeded();
      await sleep(450);
      await link.click({ timeout: 5000 });
      await page.waitForURL((url) => url.pathname === path, { timeout: 10000 });
    } catch {
      await page.goto(baseURL + path, { waitUntil: 'domcontentloaded' });
    }
  } else {
    await page.goto(baseURL + path, { waitUntil: 'domcontentloaded' });
  }
  await settle(page, 2200);
}

async function scrollWholePage(page) {
  const viewport = page.viewportSize()?.height ?? 900;
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  const maxY = Math.max(0, height - viewport);
  const step = Math.max(440, Math.floor(viewport * 0.6));

  for (let y = 0; y <= maxY; y += step) {
    await page.evaluate((top) => window.scrollTo({ top, behavior: 'smooth' }), y);
    await sleep(900);
  }
  if (maxY > 0) {
    await page.evaluate((top) => window.scrollTo({ top, behavior: 'smooth' }), maxY);
    await sleep(1100);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
    await sleep(850);
  }
}

async function clickAndWait(locator, ms = 2300) {
  if (!(await locator.count())) return false;
  await locator.scrollIntoViewIfNeeded().catch(() => {});
  await sleep(500);
  await locator.click();
  await sleep(ms);
  return true;
}

async function showReviewTabs(page) {
  for (const label of ['할 일', '결정', '변경 이력']) {
    const tab = page.getByRole('tab', { name: label, exact: true });
    if (await tab.count()) {
      await clickAndWait(tab, 1700);
      await scrollWholePage(page);
    }
  }
}

async function showTodoViews(page) {
  const trash = page.getByRole('button', { name: /휴지통/ }).first();
  if (await trash.count()) {
    await clickAndWait(trash, 1700);
    await scrollWholePage(page);
    const back = page.getByRole('button', { name: '할 일로 돌아가기', exact: true });
    if (await back.count()) await clickAndWait(back, 1700);
  }
}

async function showDocumentViews(page) {
  for (const filter of ['보관함', '전체', '사용 중']) {
    const button = page.getByRole('button', { name: filter, exact: true });
    if (await button.count()) await clickAndWait(button, 1300);
  }
  for (const view of ['카드', '달력', '목록']) {
    const button = page.getByRole('button', { name: view, exact: true });
    if (await button.count()) {
      await clickAndWait(button, 1300);
      await scrollWholePage(page);
    }
  }
}

async function selectOptionContaining(page, scope, text) {
  const combobox = scope.getByRole('combobox').first();
  if (!(await combobox.count())) return false;
  await combobox.click();
  await sleep(650);
  const option = page.getByRole('option').filter({ hasText: text }).first();
  if (!(await option.count())) {
    await page.keyboard.press('Escape').catch(() => {});
    return false;
  }
  await option.click();
  await sleep(700);
  return true;
}

async function adminCollaboration(page, path) {
  if (path === '/admin/members') {
    const applicant = page.getByText('최민지', { exact: false }).first();
    if (await applicant.count()) {
      const row = applicant.locator('xpath=ancestor::li[.//button[normalize-space(.)="승인"]][1]');
      const approve = row.getByRole('button', { name: '승인', exact: true });
      await clickAndWait(approve, 3000);
    }
  }

  if (path === '/review') {
    const candidate = page.getByDisplayValue('[촬영] 회의 후 베타 일정 공지').first();
    if (await candidate.count()) {
      const card = candidate.locator('xpath=ancestor::div[.//button[normalize-space(.)="확정"]][1]');
      await selectOptionContaining(page, card, '박준호');
      const confirm = card.getByRole('button', { name: '확정', exact: true });
      await clickAndWait(confirm, 3200);
    }
    await showReviewTabs(page);
  }

  if (path === '/admin/reassign') {
    const title = page.getByText('[촬영] 온보딩 인터뷰 3건 예약', { exact: true }).first();
    if (await title.count()) {
      const row = title.locator('xpath=ancestor::li[.//button[normalize-space(.)="재배정"]][1]');
      await selectOptionContaining(page, row, '박준호');
      const reassign = row.getByRole('button', { name: '재배정', exact: true });
      await clickAndWait(reassign, 3000);
    }
  }

  if (path === '/todos') {
    const title = page.getByText('[촬영] 배포 체크리스트 최종 검수', { exact: true }).first();
    if (await title.count()) {
      const card = title.locator('xpath=ancestor::div[.//button[normalize-space(.)="승인"]][1]');
      const approve = card.getByRole('button', { name: '승인', exact: true });
      await clickAndWait(approve, 3000);
    }
    await showTodoViews(page);
  }
}

async function memberCollaboration(page, path) {
  if (path !== '/todos') return;
  const title = page.getByText('[촬영] 검색 결과 출처 배지 추가', { exact: true }).first();
  if (await title.count()) {
    let card = title.locator('xpath=ancestor::div[.//button[contains(normalize-space(.),"도움 받음")]][1]');
    const resume = card.getByRole('button', { name: /도움 받음/ }).first();
    if (await resume.count()) {
      await clickAndWait(resume, 2800);
      const refreshed = page.getByText('[촬영] 검색 결과 출처 배지 추가', { exact: true }).first();
      card = refreshed.locator('xpath=ancestor::div[.//button[normalize-space(.)="완료 요청"]][1]');
      const request = card.getByRole('button', { name: '완료 요청', exact: true });
      await clickAndWait(request, 3000);
    }
  }
  await showTodoViews(page);
}

async function exerciseSearchAndAi(page, path) {
  if (path === '/search') {
    const input = page.locator('input:visible').first();
    if (await input.count()) {
      await input.pressSequentially('베타 일정', { delay: 95 });
      await sleep(800);
      const button = page.getByRole('button', { name: /찾기|검색/ }).first();
      if (await button.count()) {
        await button.click();
        await sleep(4500);
      }
    }
  }

  if (path === '/ask') {
    const input = page.locator('input:visible').first();
    if (await input.count()) {
      await input.pressSequentially('베타 일정이 왜 바뀌었어?', { delay: 80 });
      await sleep(800);
      const button = page.getByRole('button', { name: /답변|질문|묻기/ }).first();
      if (await button.count()) {
        await button.click();
        await sleep(6500);
      }
    }
  }

  if (path === '/context') {
    const input = page.locator('input:visible').first();
    if (await input.count()) {
      await input.pressSequentially('베타 일정 검색 근거', { delay: 80 });
      await sleep(800);
      const button = page.getByRole('button', { name: /찾기|모아보기|검색/ }).first();
      if (await button.count()) {
        await button.click();
        await sleep(5000);
      }
    }
  }
}

async function exercisePage(page, role, path) {
  if (role === 'ADMIN') await adminCollaboration(page, path);
  else await memberCollaboration(page, path);

  await exerciseSearchAndAi(page, path);
  if (path === '/review' && role !== 'ADMIN') await showReviewTabs(page);
  if (path === '/documents') await showDocumentViews(page);

  await scrollWholePage(page);
  await sleep(1300);
}

async function record(role, routes, filename) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 1,
    recordVideo: { dir: `${outDir}/raw`, size: { width: 1440, height: 900 } },
  });
  const page = await context.newPage();

  let activePath = '/login';
  const runtimeErrors = [];
  page.on('pageerror', (error) => {
    const message = `[${role}] ${activePath}: ${error.stack ?? error.message}`;
    runtimeErrors.push(message);
    console.error(message);
  });

  await page.goto(baseURL + '/login', { waitUntil: 'domcontentloaded' });
  await settle(page, 1800);
  await page.getByLabel('아이디 또는 이메일').pressSequentially(credentials[role].login, { delay: 95 });
  await page.getByLabel('비밀번호').pressSequentially(credentials[role].password, { delay: 65 });
  await sleep(900);
  await page.getByRole('button', { name: '로그인', exact: true }).click();
  await page.waitForURL((url) => url.pathname === '/', { timeout: 15000 });
  await settle(page, 2500);
  await selectDemoProject(page);
  await settle(page, 1800);

  for (const path of routes) {
    activePath = path;
    console.log(`[${role}] recording ${path}`);
    await navigateLikeUser(page, path);
    await selectDemoProject(page);
    await exercisePage(page, role, path);
    if (runtimeErrors.length) throw new Error(runtimeErrors.join('\n\n'));
  }

  const video = page.video();
  await context.close();
  if (!video) throw new Error('Playwright video was not created.');
  await video.saveAs(`${outDir}/${filename}.webm`);
  await browser.close();
}

await record('ADMIN', ADMIN_ROUTES, 'hub-production-admin-full-demo');
await record('MEMBER', MEMBER_ROUTES, 'hub-production-member-full-demo');
