import { render } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type {
	User,
	Team,
	Board,
	List,
	Card,
	Image,
	BoardData,
	Workspace,
} from "./types.ts";

type Session = { user: User; csrf: string };
let csrf = "";
function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
class ApiError extends Error {
	status: number;
	constructor(message: string, status: number) {
		super(message);
		this.status = status;
	}
}
async function api<T>(
	path: string,
	method = "GET",
	data?: unknown,
): Promise<T> {
	const res = await fetch("/api" + path, {
		method,
		headers: { "content-type": "application/json", "x-csrf-token": csrf },
		body: data === undefined ? undefined : JSON.stringify(data),
	});
	const value = await res.json();
	if (!res.ok) throw new ApiError(value.error || "Request failed", res.status);
	return value;
}
function Icon({ name }: { name: string }) {
	const paths: Record<string, string> = {
		board: "M3 3h18v18H3z M9 3v18 M15 3v18",
		plus: "M12 5v14 M5 12h14",
		close: "M6 6l12 12 M18 6L6 18",
		arrow: "M5 12h14 M13 6l6 6-6 6",
		people:
			"M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M22 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75",
		image: "M3 3h18v18H3z M3 16l5-5 4 4 3-3 6 6 M16 7h.01",
		search: "M21 21l-5-5 M10 17a7 7 0 1 0 0-14 7 7 0 0 0 0 14",
		logout: "M9 21H3V3h6 M9 12h12 M17 8l4 4-4 4",
		trash: "M3 6h18 M8 6V3h8v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7",
		check: "M5 12l4 4L19 6",
	};
	return (
		<svg
			width="18"
			height="18"
			viewBox="0 0 24 24"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.6"
			strokeLinecap="round"
			strokeLinejoin="round"
			aria-hidden="true"
		>
			<path d={paths[name] || paths.board} />
		</svg>
	);
}
function Logo() {
	return (
		<span class="logo">
			<span class="logo-mark">
				<Icon name="board" />
			</span>
			taskboard<span class="logo-dot">.</span>
		</span>
	);
}
function Modal({
	title,
	close,
	children,
}: {
	title: string;
	close: () => void;
	children: any;
}) {
	const ref = useRef<HTMLDialogElement>(null);
	useEffect(() => {
		ref.current!.showModal();
		return () => ref.current?.close();
	}, []);
	return (
		<dialog
			ref={ref}
			class="modal"
			onCancel={(e) => {
				e.preventDefault();
				close();
			}}
			onClick={(e) => {
				if (e.target === e.currentTarget) close();
			}}
		>
			<div class="modal-inner">
				<header>
					<h2>{title}</h2>
					<button class="icon-button" aria-label="Close dialog" onClick={close}>
						<Icon name="close" />
					</button>
				</header>
				{children}
			</div>
		</dialog>
	);
}
function Auth({ signedIn }: { signedIn: (s: Session) => void }) {
	const [signup, setSignup] = useState(false),
		[busy, setBusy] = useState(false),
		[error, setError] = useState("");
	async function submit(e: Event) {
		e.preventDefault();
		const f = new FormData(e.currentTarget as HTMLFormElement);
		setBusy(true);
		setError("");
		try {
			signedIn(
				await api<Session>(signup ? "/register" : "/login", "POST", {
					name: f.get("name"),
					email: f.get("email"),
					password: f.get("password"),
				}),
			);
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	return (
		<div class="auth-page">
			<header class="auth-header">
				<Logo />
				<span>A little space. A lot of possibility.</span>
			</header>
			<main class="auth-main">
				<section class="auth-story">
					<span class="eyebrow">MAKE ROOM FOR WHAT’S NEXT</span>
					<h1>
						Good ideas
						<br />
						need a place
						<br />
						<span>to grow.</span>
					</h1>
					<p>
						Bring your people, plans, and projects together.
						<br />
						One board at a time.
					</p>
					<div class="mini-board" aria-hidden="true">
						<div>
							<span class="mini-label">IDEAS</span>
							<div class="mini-card peach">
								A fresh perspective<span>● ●</span>
							</div>
							<div class="mini-card">Something worth making</div>
						</div>
						<div>
							<span class="mini-label">IN THE MAKING</span>
							<div class="mini-card lavender">
								The next big thing<span>↗</span>
							</div>
						</div>
						<div>
							<span class="mini-label">OUT IN THE WORLD</span>
							<div class="mini-card mint">
								A small win<span>✓</span>
							</div>
						</div>
					</div>
					<span class="story-foot">Less juggling. More doing.</span>
				</section>
				<section class="auth-panel">
					<span class="eyebrow">YOUR WORKSPACE AWAITS</span>
					<h2>{signup ? "Start something good." : "Welcome back."}</h2>
					<p>
						{signup
							? "Create an account and make it yours."
							: "Pick up where you left off."}
					</p>
					<form onSubmit={submit}>
						{signup && (
							<label>
								Your name
								<input
									name="name"
									required
									maxLength={80}
									autoComplete="name"
									placeholder="Alex Morgan"
								/>
							</label>
						)}
						<label>
							Email address
							<input
								type="email"
								name="email"
								required
								autoComplete="email"
								placeholder="you@example.com"
							/>
						</label>
						<label>
							Password
							<input
								type="password"
								name="password"
								required
								minLength={signup ? 15 : 1}
								maxLength={1024}
								autoComplete={signup ? "new-password" : "current-password"}
								placeholder={
									signup ? "At least 15 characters" : "Your password"
								}
							/>
						</label>
						{error && (
							<p class="error" role="alert">
								{error}
							</p>
						)}
						<button class="primary" disabled={busy}>
							{busy
								? "One moment…"
								: signup
									? "Create your workspace"
									: "Sign in"}
							<Icon name="arrow" />
						</button>
					</form>
					<p class="auth-switch">
						{signup ? "Already have an account?" : "New around here?"}{" "}
						<button
							class="text-button"
							onClick={() => {
								setSignup(!signup);
								setError("");
							}}
						>
							{signup ? "Sign in" : "Create an account"}
						</button>
					</p>
				</section>
			</main>
			<footer class="auth-footer">A calmer way to get things done.</footer>
		</div>
	);
}
function CreateModal({
	kind,
	close,
	save,
}: {
	kind: string;
	close: () => void;
	save: (name: string) => Promise<void>;
}) {
	const [busy, setBusy] = useState(false),
		[error, setError] = useState("");
	async function submit(e: Event) {
		e.preventDefault();
		setBusy(true);
		try {
			await save(
				String(new FormData(e.currentTarget as HTMLFormElement).get("name")),
			);
			close();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	return (
		<Modal title={`New ${kind}`} close={close}>
			<form onSubmit={submit}>
				<label>
					{kind} name
					<input
						name="name"
						required
						maxLength={80}
						autoFocus
						placeholder={
							kind === "team" ? "Your next collaboration" : "Give it a name"
						}
					/>
				</label>
				{error && (
					<p class="error" role="alert">
						{error}
					</p>
				)}
				<button class="primary" disabled={busy}>
					{busy ? "Creating…" : `Create ${kind}`}
				</button>
			</form>
		</Modal>
	);
}
function Members({
	team,
	user,
	close,
}: {
	team: Team;
	user: User;
	close: () => void;
}) {
	const [members, setMembers] = useState<User[]>([]),
		[error, setError] = useState(""),
		[busy, setBusy] = useState(false);
	async function load() {
		try {
			setMembers(await api<User[]>(`/teams/${team.id}/members`));
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	useEffect(() => {
		load();
	}, [team.id]);
	async function add(e: Event) {
		e.preventDefault();
		const form = e.currentTarget as HTMLFormElement;
		setBusy(true);
		setError("");
		try {
			await api(`/teams/${team.id}/members`, "POST", {
				email: new FormData(form).get("email"),
			});
			form.reset();
			await load();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	async function remove(member: User) {
		if (!confirm(`Remove ${member.name} from ${team.name}?`)) return;
		try {
			await api(`/teams/${team.id}/members/${member.id}`, "DELETE");
			await load();
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	return (
		<Modal title={team.name} close={close}>
			<p class="muted">Good work starts with good people.</p>
			<div class="members">
				{members.map((m) => (
					<div key={m.id} class="member">
						<span class="avatar">{m.name[0].toUpperCase()}</span>
						<div>
							<strong>{m.name}</strong>
							<small>{m.email}</small>
						</div>
						{m.id === team.owner_id ? (
							<span class="pill">Owner</span>
						) : (
							team.owner_id === user.id && (
								<button
									class="icon-button"
									onClick={() => remove(m)}
									aria-label={`Remove ${m.name}`}
								>
									<Icon name="close" />
								</button>
							)
						)}
					</div>
				))}
			</div>
			{team.owner_id === user.id && (
				<form onSubmit={add}>
					<label>
						Add someone by email
						<input
							type="email"
							name="email"
							placeholder="teammate@example.com"
							required
						/>
					</label>
					<p class="hint">They’ll need to create an account first.</p>
					<button class="primary" disabled={busy}>
						Add to team
						<Icon name="plus" />
					</button>
				</form>
			)}
			{error && (
				<p class="error" role="alert">
					{error}
				</p>
			)}
		</Modal>
	);
}
function CardEditor({
	card,
	data,
	close,
	changed,
}: {
	card: Card;
	data: BoardData;
	close: () => void;
	changed: () => Promise<void>;
}) {
	const [error, setError] = useState(""),
		[busy, setBusy] = useState(false),
		[color, setColor] = useState(card.color),
		[uploading, setUploading] = useState(false);
	const images = data.images.filter((i) => i.card_id === card.id);
	async function save(e: Event) {
		e.preventDefault();
		const f = new FormData(e.currentTarget as HTMLFormElement);
		setBusy(true);
		setError("");
		try {
			await api(`/cards/${card.id}`, "PATCH", {
				title: f.get("title"),
				description: f.get("description"),
				list_id: Number(f.get("list_id")),
				color,
			});
			await changed();
			close();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	async function remove() {
		if (!confirm("Delete this card and its images?")) return;
		setBusy(true);
		try {
			await api(`/cards/${card.id}`, "DELETE");
			await changed();
			close();
		} catch (e) {
			setError(errorMessage(e));
			setBusy(false);
		}
	}
	async function upload(e: Event) {
		const input = e.currentTarget as HTMLInputElement,
			file = input.files?.[0];
		if (!file) return;
		if (file.size > 5 * 1024 * 1024) {
			setError("Images must be under 5 MiB");
			return;
		}
		setUploading(true);
		setError("");
		try {
			const r = await fetch(`/api/cards/${card.id}/images`, {
				method: "POST",
				headers: {
					"content-type": file.type,
					"x-file-name": encodeURIComponent(file.name),
					"x-csrf-token": csrf,
				},
				body: file,
			});
			const value = await r.json();
			if (!r.ok) throw new Error(value.error);
			await changed();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setUploading(false);
			input.value = "";
		}
	}
	async function removeImage(image: Image) {
		if (!confirm(`Remove ${image.name}?`)) return;
		try {
			await api(`/images/${image.id}`, "DELETE");
			await changed();
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	return (
		<Modal title="A closer look" close={close}>
			<form onSubmit={save}>
				<label>
					Card title
					<input
						name="title"
						defaultValue={card.title}
						maxLength={200}
						required
						autoFocus
					/>
				</label>
				<label>
					Description
					<textarea
						name="description"
						defaultValue={card.description}
						rows={5}
						maxLength={8000}
						placeholder="Add a little context, a big idea, or the next step…"
					/>
				</label>
				<div class="editor-row">
					<label>
						List
						<select name="list_id" defaultValue={card.list_id}>
							{data.lists.map((l) => (
								<option value={l.id} key={l.id}>
									{l.name}
								</option>
							))}
						</select>
					</label>
					<fieldset class="color-picker">
						<legend>Color</legend>
						{["none", "mint", "peach", "lavender", "sky"].map((c) => (
							<button
								type="button"
								key={c}
								class={`swatch ${c} ${color === c ? "selected" : ""}`}
								onClick={() => setColor(c)}
								aria-label={c === "none" ? "No color" : c}
								aria-pressed={color === c}
							>
								{color === c && <Icon name="check" />}
							</button>
						))}
					</fieldset>
				</div>
				<section class="attachments">
					<div class="section-label">
						<span>
							Images <span class="count">{images.length}</span>
						</span>
						<label class="upload-button">
							<Icon name="image" />
							{uploading ? "Uploading…" : "Attach image"}
							<input
								type="file"
								accept="image/png,image/jpeg,image/gif,image/webp"
								onChange={upload}
								disabled={uploading}
								aria-label="Attach image"
							/>
						</label>
					</div>
					<div class="image-grid">
						{images.map((image) => (
							<figure key={image.id}>
								<a
									href={`/api/images/${image.id}`}
									target="_blank"
									rel="noopener"
								>
									<img src={`/api/images/${image.id}`} alt={image.name} />
								</a>
								<figcaption>
									<span>{image.name}</span>
									<button
										type="button"
										class="icon-button"
										aria-label={`Remove ${image.name}`}
										onClick={() => removeImage(image)}
									>
										<Icon name="close" />
									</button>
								</figcaption>
							</figure>
						))}
					</div>
					<p class="hint">PNG, JPEG, GIF or WebP · up to 5 MiB each</p>
				</section>
				{error && (
					<p class="error" role="alert">
						{error}
					</p>
				)}
				<div class="modal-actions">
					<button
						type="button"
						class="danger text-button"
						disabled={busy || uploading}
						onClick={remove}
					>
						<Icon name="trash" />
						Delete card
					</button>
					<button class="primary" disabled={busy || uploading}>
						{busy ? "Saving…" : "Save changes"}
					</button>
				</div>
			</form>
		</Modal>
	);
}
function Column({
	list,
	cards,
	images,
	openCard,
	changed,
	move,
	report,
}: {
	list: List;
	cards: Card[];
	images: Image[];
	openCard: (c: Card) => void;
	changed: () => Promise<void>;
	move: (id: number, list: number) => Promise<void>;
	report: (e: unknown) => void;
}) {
	const [adding, setAdding] = useState(false),
		[busy, setBusy] = useState(false),
		[over, setOver] = useState(false);
	async function add(e: Event) {
		e.preventDefault();
		const form = e.currentTarget as HTMLFormElement;
		setBusy(true);
		try {
			await api("/cards", "POST", {
				list_id: list.id,
				title: new FormData(form).get("title"),
			});
			form.reset();
			setAdding(false);
			await changed();
		} catch (e) {
			report(e);
		} finally {
			setBusy(false);
		}
	}
	async function remove() {
		if (!confirm(`Delete “${list.name}” and all its cards?`)) return;
		try {
			await api(`/lists/${list.id}`, "DELETE");
			await changed();
		} catch (e) {
			report(e);
		}
	}
	async function rename() {
		const name = prompt("List name", list.name);
		if (!name || name === list.name) return;
		try {
			await api(`/lists/${list.id}`, "PATCH", { name });
			await changed();
		} catch (e) {
			report(e);
		}
	}
	return (
		<section
			class={`column ${over ? "drop-target" : ""}`}
			onDragOver={(e) => {
				e.preventDefault();
				setOver(true);
			}}
			onDragLeave={(e) => {
				if (!e.currentTarget.contains(e.relatedTarget as Node)) setOver(false);
			}}
			onDrop={(e) => {
				e.preventDefault();
				setOver(false);
				const id = Number(e.dataTransfer?.getData("text/taskboard-card"));
				if (id) move(id, list.id);
			}}
		>
			<header class="column-header">
				<button class="list-name" onClick={rename} title="Rename list">
					{list.name}
				</button>
				<span class="count">{cards.length}</span>
				<button
					class="icon-button list-delete"
					aria-label={`Delete ${list.name}`}
					onClick={remove}
				>
					<Icon name="trash" />
				</button>
			</header>
			<div class="card-stack">
				{cards.map((c) => {
					const imgs = images.filter((i) => i.card_id === c.id);
					return (
						<button
							key={c.id}
							class={`card ${c.color}`}
							draggable
							onDragStart={(e) => {
								e.dataTransfer!.setData("text/taskboard-card", String(c.id));
								e.dataTransfer!.effectAllowed = "move";
							}}
							onClick={() => openCard(c)}
						>
							{imgs[0] && (
								<img
									class="card-cover"
									src={`/api/images/${imgs[0].id}`}
									alt=""
								/>
							)}
							{c.color !== "none" && <span class={`card-label ${c.color}`} />}
							<span class="card-title">{c.title}</span>
							{(c.description || imgs.length > 0) && (
								<span class="card-meta">
									{c.description && <span>≡</span>}
									{imgs.length > 0 && (
										<span>
											<Icon name="image" />
											{imgs.length}
										</span>
									)}
								</span>
							)}
						</button>
					);
				})}
			</div>
			{adding ? (
				<form class="add-card" onSubmit={add}>
					<textarea
						name="title"
						required
						maxLength={200}
						rows={2}
						placeholder="What needs doing?"
						autoFocus
					/>
					<div>
						<button class="small primary" disabled={busy}>
							{busy ? "Adding…" : "Add card"}
						</button>
						<button
							type="button"
							class="icon-button"
							aria-label="Cancel adding card"
							onClick={() => setAdding(false)}
						>
							<Icon name="close" />
						</button>
					</div>
				</form>
			) : (
				<button class="add-card-button" onClick={() => setAdding(true)}>
					<Icon name="plus" />
					Add a card
				</button>
			)}
		</section>
	);
}
function App() {
	const [user, setUser] = useState<User | null>(null),
		[ready, setReady] = useState(false),
		[workspace, setWorkspace] = useState<Workspace>({ teams: [], boards: [] });
	const [teamId, setTeamId] = useState(0),
		[boardId, setBoardId] = useState(0),
		[data, setData] = useState<BoardData | null>(null),
		[error, setError] = useState(""),
		[loading, setLoading] = useState(false);
	const [search, setSearch] = useState(""),
		[modal, setModal] = useState(""),
		[cardId, setCardId] = useState(0),
		[sidebar, setSidebar] = useState(false);
	const requestSerial = useRef(0),
		boardRef = useRef(0);
	boardRef.current = boardId;
	function signedIn(s: Session) {
		csrf = s.csrf;
		setUser(s.user);
		setError("");
	}
	function report(e: unknown) {
		setError(errorMessage(e));
		if (e instanceof ApiError && e.status === 401) {
			csrf = "";
			setUser(null);
			setWorkspace({ teams: [], boards: [] });
			setData(null);
			setBoardId(0);
			setTeamId(0);
			setModal("");
			setCardId(0);
		}
	}
	useEffect(() => {
		api<Session>("/me")
			.then(signedIn)
			.catch((e) => {
				if (e.status !== 401) setError(errorMessage(e));
			})
			.finally(() => setReady(true));
	}, []);
	async function loadWorkspace() {
		const w = await api<Workspace>("/workspace");
		setWorkspace(w);
		return w;
	}
	useEffect(() => {
		if (!user) return;
		loadWorkspace()
			.then((w) => {
				const first = w.boards[0];
				setTeamId(first?.team_id || w.teams[0]?.id || 0);
				setBoardId(first?.id || 0);
			})
			.catch(report);
	}, [user?.id]);
	async function loadBoard(id = boardRef.current) {
		if (!id) {
			setData(null);
			return;
		}
		const serial = ++requestSerial.current;
		setLoading(true);
		try {
			const value = await api<BoardData>(`/boards/${id}`);
			if (serial === requestSerial.current && boardRef.current === id)
				setData(value);
		} catch (e) {
			if (serial === requestSerial.current) {
				setData(null);
				report(e);
			}
		} finally {
			if (serial === requestSerial.current) setLoading(false);
		}
	}
	useEffect(() => {
		setData(null);
		setSearch("");
		setCardId(0);
		loadBoard(boardId);
	}, [boardId]);
	useEffect(() => {
		if (!user || !boardId) return;
		const onFocus = () => {
			loadBoard();
		};
		window.addEventListener("focus", onFocus);
		const tick = setInterval(() => {
			if (
				!document.hidden &&
				document.activeElement?.tagName !== "INPUT" &&
				document.activeElement?.tagName !== "TEXTAREA" &&
				!modal &&
				!cardId
			)
				loadBoard();
		}, 15000);
		return () => {
			window.removeEventListener("focus", onFocus);
			clearInterval(tick);
		};
	}, [user?.id, boardId, modal, cardId]);
	function chooseTeam(id: number) {
		setTeamId(id);
		setBoardId(workspace.boards.find((b) => b.team_id === id)?.id || 0);
		setSidebar(false);
	}
	async function create(kind: string, name: string) {
		if (kind === "list") {
			await api("/lists", "POST", { board_id: boardId, name });
			await loadBoard();
			return;
		}
		const result = await api<{ id: number }>(
			kind === "team" ? "/teams" : "/boards",
			"POST",
			kind === "team" ? { name } : { name, team_id: teamId },
		);
		const w = await loadWorkspace();
		if (kind === "team") {
			setTeamId(result.id);
			setBoardId(w.boards.find((b) => b.team_id === result.id)?.id || 0);
		} else {
			setBoardId(result.id);
		}
	}
	async function move(id: number, listId: number) {
		try {
			await api(`/cards/${id}`, "PATCH", { list_id: listId });
			await loadBoard();
		} catch (e) {
			report(e);
		}
	}
	async function logout() {
		try {
			await api("/logout", "POST");
			csrf = "";
			setUser(null);
			setData(null);
			setWorkspace({ teams: [], boards: [] });
			setBoardId(0);
			setTeamId(0);
			setSidebar(false);
		} catch (e) {
			report(e);
		}
	}
	async function deleteBoard() {
		if (!confirm(`Delete “${data?.board.name}” and all its cards?`)) return;
		try {
			await api(`/boards/${boardId}`, "DELETE");
			const w = await loadWorkspace();
			setBoardId(w.boards.find((b) => b.team_id === teamId)?.id || 0);
		} catch (e) {
			report(e);
		}
	}
	if (!ready)
		return (
			<div class="loading">
				<Logo />
				<span>Opening your workspace…</span>
			</div>
		);
	if (!user)
		return (
			<>
				<Auth signedIn={signedIn} />
				{error && (
					<div class="toast error" role="alert">
						{error}
					</div>
				)}
			</>
		);
	const team = workspace.teams.find((t) => t.id === teamId),
		boards = workspace.boards.filter((b) => b.team_id === teamId),
		card = data?.cards.find((c) => c.id === cardId);
	const shown =
		data?.cards.filter((c) =>
			(c.title + " " + c.description)
				.toLowerCase()
				.includes(search.toLowerCase()),
		) || [];
	return (
		<div class="workspace">
			<aside class={`sidebar ${sidebar ? "open" : ""}`}>
				<div class="sidebar-logo">
					<Logo />
					<button
						class="icon-button mobile-only"
						aria-label="Close navigation"
						onClick={() => setSidebar(false)}
					>
						<Icon name="close" />
					</button>
				</div>
				<div class="workspace-picker">
					<label for="team-select">WORKSPACE</label>
					<select
						id="team-select"
						value={teamId}
						onChange={(e) => chooseTeam(Number(e.currentTarget.value))}
					>
						{workspace.teams.map((t) => (
							<option value={t.id} key={t.id}>
								{t.name}
							</option>
						))}
					</select>
				</div>
				<nav>
					<div class="nav-heading">
						<span>YOUR BOARDS</span>
						<button
							class="icon-button"
							aria-label="Create board"
							disabled={!teamId}
							onClick={() => setModal("board")}
						>
							<Icon name="plus" />
						</button>
					</div>
					{boards.map((b) => (
						<button
							key={b.id}
							class={`nav-board ${b.id === boardId ? "active" : ""}`}
							onClick={() => {
								setBoardId(b.id);
								setSidebar(false);
							}}
						>
							<Icon name="board" />
							{b.name}
							{b.id === boardId && <span class="active-dot" />}
						</button>
					))}
					{!boards.length && (
						<p class="hint nav-empty">A fresh start. Add your first board.</p>
					)}
					<button
						class="nav-board"
						onClick={() => setModal("members")}
						disabled={!team}
					>
						<Icon name="people" />
						Team members
					</button>
				</nav>
				<div class="sidebar-bottom">
					<button class="nav-board" onClick={() => setModal("team")}>
						<Icon name="plus" />
						New workspace
					</button>
					<div class="sidebar-note">
						<span>MAKE A LITTLE PROGRESS</span>
						<p>
							Small steps.
							<br />
							Good things ahead.
						</p>
						<span class="note-doodle">✳</span>
					</div>
					<div class="account">
						<span class="avatar">{user.name[0].toUpperCase()}</span>
						<div>
							<strong>{user.name}</strong>
							<small>Room to make things happen</small>
						</div>
						<button class="icon-button" aria-label="Sign out" onClick={logout}>
							<Icon name="logout" />
						</button>
					</div>
				</div>
			</aside>
			<main class="board-main">
				<header class="topbar">
					<button
						class="icon-button mobile-only"
						aria-label="Open navigation"
						onClick={() => setSidebar(true)}
					>
						<Icon name="board" />
					</button>
					<span>
						{team?.name || "Your workspace"}
						<span class="breadcrumb-divider">/</span>
						<strong>{data?.board.name || "Boards"}</strong>
					</span>
					<span class="topbar-status">
						<span class="status-dot" />
						{loading ? "Updating…" : "All changes saved"}
					</span>
				</header>
				<section class="board-heading">
					<div>
						<span class="eyebrow">A PLACE TO MAKE THINGS HAPPEN</span>
						<h1>
							{data?.board.name || "Your next chapter"}
							<span class="heading-star">✳</span>
						</h1>
						<p>Big picture. Small steps. Let’s get there together.</p>
					</div>
					<div class="board-tools">
						<label class="search">
							<Icon name="search" />
							<input
								value={search}
								onInput={(e) => setSearch(e.currentTarget.value)}
								placeholder="Find a card…"
								aria-label="Find a card"
							/>
						</label>
						<button
							class="secondary"
							onClick={() => setModal("members")}
							disabled={!team}
						>
							<Icon name="people" />
							Team
						</button>
					</div>
				</section>
				{error && (
					<div class="board-error error" role="alert">
						<span>{error}</span>
						<button
							class="icon-button"
							aria-label="Dismiss error"
							onClick={() => setError("")}
						>
							<Icon name="close" />
						</button>
					</div>
				)}
				{data ? (
					<>
						<div class="board-canvas">
							{data.lists.map((l) => (
								<Column
									key={l.id}
									list={l}
									cards={shown.filter((c) => c.list_id === l.id)}
									images={data.images}
									openCard={(c) => setCardId(c.id)}
									changed={loadBoard}
									move={move}
									report={report}
								/>
							))}
							<button class="add-list" onClick={() => setModal("list")}>
								<Icon name="plus" />
								Add a list
							</button>
						</div>
						<footer class="board-footer">
							<span>
								{data.cards.length} cards · {data.lists.length} lists
								<span class="footer-separator">/</span>Drag to move. Click to
								make it yours.
							</span>
							<button class="text-button muted" onClick={deleteBoard}>
								Delete board
							</button>
						</footer>
					</>
				) : (
					<div class="empty-board">
						<Icon name="board" />
						<h2>
							{loading
								? "Opening your board…"
								: "A blank canvas, just for you."}
						</h2>
						{!loading && (
							<button
								class="primary"
								onClick={() => setModal("board")}
								disabled={!teamId}
							>
								Create a board
								<Icon name="plus" />
							</button>
						)}
					</div>
				)}
			</main>
			{["team", "board", "list"].includes(modal) && (
				<CreateModal
					kind={modal}
					close={() => setModal("")}
					save={(name) => create(modal, name)}
				/>
			)}{" "}
			{modal === "members" && team && (
				<Members team={team} user={user} close={() => setModal("")} />
			)}{" "}
			{card && data && (
				<CardEditor
					key={card.id}
					card={card}
					data={data}
					close={() => setCardId(0)}
					changed={loadBoard}
				/>
			)}
		</div>
	);
}
render(<App />, document.getElementById("app")!);
