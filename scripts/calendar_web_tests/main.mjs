import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("Quake4Mac/Web/calendar.html", "utf8");
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
const styleMatch = html.match(/<style>([\s\S]*?)<\/style>/);
assert.ok(scriptMatch, "calendar.html contains an inline script");
assert.ok(styleMatch, "calendar.html contains inline styles");

function cssRule(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = styleMatch[1].match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`));
  assert.ok(match, `style rule exists for ${selector}`);
  return match[1];
}

function makeElement() {
  const classes = new Set();
  return {
    classList: {
      toggle(name, force) {
        if (force) classes.add(name);
        else classes.delete(name);
      },
      contains(name) {
        return classes.has(name);
      },
    },
    textContent: "",
    innerHTML: "",
    scrollTop: 0,
    onclick: null,
  };
}

function loadCalendarPage() {
  const ids = ["app", "date", "dateCard", "dateLarge", "dateWeekday", "request", "focus", "count", "caption", "events"];
  const elements = Object.fromEntries(ids.map((id) => [id, makeElement()]));
  const posts = [];
  const context = {
    window: {
      webkit: {
        messageHandlers: {
          calendar: {
            postMessage(action) {
              posts.push(action);
            },
          },
        },
      },
    },
    document: {
      getElementById(id) {
        return elements[id] ?? makeElement();
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(scriptMatch[1], context);
  return { elements, posts, calendar: context.window.CAL };
}

function setState(page, status, dateTitle = "Today") {
  page.calendar.set(JSON.stringify({
    status,
    dateTitle,
    message: "Calendar access needed",
    events: [],
    canOpenFantastical: false,
  }));
}

function setAuthorizedEvents(page, events) {
  page.calendar.set(JSON.stringify({
    status: "authorized",
    dateTitle: "Today",
    message: `${events.length} events today`,
    events,
    canOpenFantastical: true,
  }));
}

function event(id, title, overrides = {}) {
  return {
    id,
    title,
    timeText: "10:00 AM-11:00 AM",
    calendarName: "Work",
    location: "",
    calendarColorHex: "#7ee35f",
    isAllDay: false,
    isNow: false,
    isNext: false,
    ...overrides,
  };
}

function articleClassForTitle(html, title) {
  const articles = html.match(/<article class="[^"]+"[^>]*>[\s\S]*?<\/article>/g) ?? [];
  const article = articles.find((candidate) => candidate.includes(title));
  assert.ok(article, `event card exists for ${title}`);
  const classMatch = article.match(/<article class="([^"]+)"/);
  assert.ok(classMatch, `event card class exists for ${title}`);
  return classMatch[1];
}

{
  const page = loadCalendarPage();
  setState(page, "notDetermined", "Friday, Jun 26");
  assert.equal(page.elements.dateLarge.textContent, "Jun 26", "left card shows today's date instead of event count");
  assert.equal(page.elements.dateWeekday.textContent, "Friday", "left card keeps the weekday as supporting context");
  assert.equal(page.elements.request.classList.contains("hidden"), false, "notDetermined shows Allow Calendar");
  assert.equal(page.elements.request.textContent, "Allow Calendar");
  page.elements.request.onclick();
  assert.deepEqual(page.posts, ["requestAccess"]);
}

{
  const page = loadCalendarPage();
  setState(page, "denied");
  assert.equal(page.elements.request.classList.contains("hidden"), false, "denied shows Settings shortcut");
  assert.equal(page.elements.request.textContent, "Open Settings");
  page.elements.request.onclick();
  assert.deepEqual(page.posts, ["openCalendarPrivacy"]);
}

{
  assert.doesNotMatch(html, /<button[^>]*id="open"/, "calendar does not render a separate Open Fantastical button");
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("next", "Helen Doron Englisch", { isNext: true }),
  ]);
  assert.equal(page.elements.dateCard.classList.contains("launchable"), true, "date card shows it can launch Fantastical");
  page.elements.dateCard.onclick();
  assert.deepEqual(page.posts, ["openFantastical"], "tapping the date card opens Fantastical");
}

{
  const metaRule = cssRule(".event-meta");
  const focusRowRule = cssRule(".focus-row");
  const focusTimeRule = cssRule(".focus-time");
  const focusMetaRule = cssRule(".focus .meta");
  const metaSpanRule = cssRule(".event-meta span");
  const dateCardRule = cssRule(".date-card");
  const dateLargeRule = cssRule(".date-large");
  const eventPastRule = cssRule(".event.past");
  const compactAppMainRule = cssRule("#app.compact main");
  const compactEventsRule = cssRule(".events.compact");
  const compactMetaRule = cssRule(".events.compact .event-meta");
  assert.match(metaRule, /flex-wrap:\s*wrap/, "event metadata wraps onto additional lines");
  assert.match(metaRule, /font-size:\s*19px/, "event metadata is large enough to read");
  assert.match(focusRowRule, /grid-template-columns:\s*160px\s+minmax\(0,\s*1fr\)/, "NEXT event places time left of the title");
  assert.match(focusTimeRule, /font-size:\s*26px/, "NEXT event time is prominent");
  assert.match(focusMetaRule, /font-size:\s*19px/, "NEXT event metadata is large enough to read");
  assert.match(dateCardRule, /width:\s*300px/, "left date card is large and square");
  assert.match(dateCardRule, /height:\s*300px/, "left date card is large and square");
  assert.match(dateLargeRule, /font-size:\s*76px/, "left date card has larger date text");
  assert.match(eventPastRule, /filter:\s*brightness\(\.7\)/, "past events are roughly 30 percent darker");
  assert.match(compactAppMainRule, /grid-template-rows:\s*108px\s+minmax\(0,\s*1fr\)/, "compact mode gives the list more vertical space");
  assert.match(compactEventsRule, /grid-template-rows:\s*repeat\(3,\s*minmax\(0,\s*1fr\)\)/, "compact mode fits three event rows");
  assert.match(compactMetaRule, /max-height:\s*40px/, "compact mode caps metadata height so cards stay fully visible");
  assert.doesNotMatch(metaSpanRule, /white-space:\s*nowrap/, "event metadata values can wrap");
  assert.doesNotMatch(metaSpanRule, /text-overflow:\s*ellipsis/, "event metadata values are not ellipsized");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("next", "Helen Doron Englisch", {
      timeText: "3:00 PM-3:45 PM",
      calendarName: "Family calendar",
      location: "Helen Doron English Altenhöferallee 80, 60438 Frankfurt am Main, Deutschland",
      isNext: true,
    }),
  ]);
  assert.equal(page.elements.date.textContent, "Next at 3:00 PM", "brand subhead summarizes the next event");
  assert.match(page.elements.focus.innerHTML, /class="focus-row"/, "NEXT event uses row layout");
  assert.match(page.elements.focus.innerHTML, /class="focus-time"/, "NEXT event renders time in a dedicated column");
  assert.doesNotMatch(page.elements.focus.innerHTML, /3:00 PM-3:45 PM.*Family calendar/, "NEXT metadata no longer repeats time inline");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("first", "First event"),
    event("second", "Second event"),
    event("third", "Third event"),
    event("fourth", "Fourth event"),
    event("fifth", "Fifth event"),
    event("sixth", "Sixth event"),
  ]);
  assert.equal(page.elements.app.classList.contains("compact"), true, "five or more events enable compact page layout");
  assert.equal(page.elements.events.classList.contains("compact"), true, "five or more events enable compact event grid");
  const htmlOrder = [
    page.elements.events.innerHTML.indexOf("First event"),
    page.elements.events.innerHTML.indexOf("Fourth event"),
    page.elements.events.innerHTML.indexOf("Second event"),
    page.elements.events.innerHTML.indexOf("Fifth event"),
    page.elements.events.innerHTML.indexOf("Third event"),
    page.elements.events.innerHTML.indexOf("Sixth event"),
  ];
  assert.deepEqual([...htmlOrder].sort((a, b) => a - b), htmlOrder, "compact event cards render as first/fourth/second/fifth/third/sixth for 2x3 visual order");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("first", "First event"),
    event("second", "Second event"),
    event("third", "Third event"),
    event("fourth", "Fourth event"),
  ]);
  const htmlOrder = [
    page.elements.events.innerHTML.indexOf("First event"),
    page.elements.events.innerHTML.indexOf("Third event"),
    page.elements.events.innerHTML.indexOf("Second event"),
    page.elements.events.innerHTML.indexOf("Fourth event"),
  ];
  assert.deepEqual([...htmlOrder].sort((a, b) => a - b), htmlOrder, "event cards render as first/third/second/fourth for column-major visual order");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("past", "Past event", { timeText: "9:00 AM-10:00 AM", end: 1 }),
    event("now", "Current event", { timeText: "10:00 AM-11:00 AM", end: 4102444800, isNow: true }),
  ]);
  assert.equal(page.elements.date.textContent, "Now until 11:00 AM", "brand subhead summarizes current event");
  assert.match(articleClassForTitle(page.elements.events.innerHTML, "Past event"), /\bpast\b/, "ended events render as past");
  assert.doesNotMatch(articleClassForTitle(page.elements.events.innerHTML, "Current event"), /\bpast\b/, "current events are not marked past");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, [
    event("past", "Past event", { end: 1 }),
    event("next", "Next event", { end: 4102444800, isNext: true }),
    event("future", "Later future event", { end: 4102448400 }),
  ]);
  assert.match(articleClassForTitle(page.elements.events.innerHTML, "Past event"), /\bpast\b/, "ended events render as past");
  assert.doesNotMatch(articleClassForTitle(page.elements.events.innerHTML, "Later future event"), /\bpast\b/, "future events after NEXT are not marked past");
}

{
  const page = loadCalendarPage();
  setAuthorizedEvents(page, []);
  assert.equal(page.elements.date.textContent, "No events left", "brand subhead summarizes an empty remaining day");
}

console.log("PASS calendar web");
