import { useEffect, useRef } from "preact/hooks";

export function Icon({ name }: { name: string }) {
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
export function Logo() {
	return (
		<span class="logo">
			<span class="logo-mark">
				<Icon name="board" />
			</span>
			taskboard<span class="logo-dot">.</span>
		</span>
	);
}
export function Modal({
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
