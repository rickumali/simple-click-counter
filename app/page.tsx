"use client";

import { useState } from "react";

export default function Home() {
  const [count, setCount] = useState(0);

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-6">
      <h1 className="text-4xl font-semibold">Hello World</h1>
      <button
        onClick={() => setCount(count + 1)}
        className="rounded-xl bg-blue-600 px-8 py-4 text-2xl font-bold text-white hover:bg-blue-700 active:scale-95 transition-all"
      >
        Count: {count}
      </button>
      <button
        onClick={() => setCount(0)}
        className="rounded-xl bg-gray-200 px-6 py-2 text-lg font-semibold text-gray-800 hover:bg-gray-300 active:scale-95 transition-all"
      >
        Reset
      </button>
    </div>
  );
}
