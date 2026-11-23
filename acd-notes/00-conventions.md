# ACD course conventions (5COSC026W) — digest of the lectures; the TASK always overrides this

## Stack and style
- React 19 + TypeScript (Vite) unless the task says JavaScript/JSX. Function components and hooks only. Functional, readable code.
- Project layout: `src/pages` (route views), `src/components` (reusable UI), `src/services` (HTTP calls), `src/hooks`, `src/types` (interfaces), `src/stores` (Zustand). Each module has one reason to change.
- Types: `interface` for object shapes (optional property `description?: string`), `type` for aliases and unions (`string | number`). Type API data; avoid `any`.
- API access lives in a service module that returns Promises (`fetch` + `await response.json()`; check `response.ok`; throw on failure). Components never build URLs inline.

## Routing (React Router, imported from `react-router-dom`)
- `BrowserRouter` > `Routes` > `Route path element`. Shared layout: a layout route whose component renders the Navbar and `<Outlet />` for the matched child.
- Dynamic route `/events/:id`: `const { id } = useParams();` — the value is a string; convert/validate it. Query string: `useSearchParams()`.
- `<Link to="/events">` for links the user clicks; `const navigate = useNavigate(); navigate("/events/42")` after an action (save, login).
- Add a catch-all `path="*"` not-found route. Distinguish route-not-found, record-not-found (404 from the API), loading and failed states.

## Fetching and state
- Local UI state: `useState`/`useReducer`. Manual fetch: `useEffect` + `useState` for data/loading/error, an `AbortController` aborted in the cleanup function, and ignore results after unmount.
- Server data: TanStack Query. `QueryClientProvider` with a `QueryClient`; `useQuery({ queryKey: ["events"], queryFn })` exposes `data`, `isPending`, `isError`, `error`; `staleTime` = how long cached data is fresh. Writes: `useMutation`, then `queryClient.invalidateQueries({ queryKey: ["events"] })` in `onSuccess` marks matching queries stale and refetches active ones.
- Shared client state (e.g. ticket basket): Zustand `create<State>()((set) => ({ ... }))`; components read with selectors `useStore(s => s.quantities[id] ?? 1)`; no provider needed. Do not put server data in Zustand.
- Show useful UI states: loading message, error message (`role="alert"`), empty state, then the data.

## Forms and validation
- Controlled inputs (`value` + `onChange`), validation on submit with an errors object shown next to each field, `e.preventDefault()`, disable the submit button while pending. Client-side validation improves UX only — the server must validate too.
- CRUD maps to HTTP: POST create (201), GET read, PUT/PATCH update, DELETE remove (204 No Content).

## HTTP and security (front end)
- 401 = not authenticated (missing/invalid/expired token) → send the user to log in. 403 = authenticated but not permitted. 404 = not found. 204 = success with no body.
- JWT: sent as `Authorization: Bearer <token>`; claims include `exp` (expiry) and `role`; a JWT is signed, not encrypted — never put secrets in it. A front-end role check or protected route is UX, not security. Protected routes: a component that renders `<Navigate to="/login" />` when there is no valid session, else `<Outlet />`. Keep session in an `AuthContext`.
- Avoid `dangerouslySetInnerHTML`; never trust data that came from a URL or API for HTML.

## HTML5, CSS3, responsive and accessible UI
- Semantic HTML (`header`, `nav`, `main`, `section`, `button` for actions, `label` for every form control, `alt` on images, one `h1`, no skipped heading levels). Visible focus: `:focus-visible`. Use ARIA only when no semantic element fits.
- Relative units (`rem`, `%`, `fr`, `ch`); `margin-inline: auto` for a centred container; media queries mobile-first at 576/768/992/1200 px; CSS Grid `grid-template-columns: repeat(auto-fit, minmax(250px, 1fr))`, `grid-template-areas` for named areas, `clamp(min, preferred, max)` for fluid sizes; Flexbox for one-dimensional layout; `loading="lazy"` on below-the-fold images.

## Bootstrap (5)
- `container` > `row` > `col-12 col-md-6 col-lg-4` (columns always inside a row); utilities `my-4 mb-3 ms-auto text-center`; `display-4` headings, `lead` text; `navbar navbar-expand-sm` with `data-bs-toggle="collapse"` (needs the Bootstrap JS bundle); `card`, `btn btn-primary`, `form-control`, `form-label`, `alert alert-danger`.
