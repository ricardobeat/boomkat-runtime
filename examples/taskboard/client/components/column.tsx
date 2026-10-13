import { useState } from "preact/hooks";
import { api } from "../lib/api.js";
import { Icon } from "./common.js";
import type { Card, List, Image } from "../../types.ts";

export function Column({
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
