import { useEffect, useRef, useState } from "preact/hooks";
import { api, setCsrf } from "../lib/api.js";
import { ApiError, errorMessage } from "../lib/errors.js";
import { Icon, Logo } from "./common.js";
import { Auth } from "./auth.js";
import { CreateModal } from "./create-modal.js";
import { Members } from "./members.js";
import { CardEditor } from "./card-editor.js";
import { Column } from "./column.js";
import type { User, Workspace, BoardData, Session } from "../../types.ts";

export function App() {
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
		setCsrf(s.csrf);
		setUser(s.user);
		setError("");
	}
	function report(e: unknown) {
		setError(errorMessage(e));
		if (e instanceof ApiError && e.status === 401) {
			setCsrf("");
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
			setCsrf("");
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
