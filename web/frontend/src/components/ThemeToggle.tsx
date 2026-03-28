import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { Sun, Moon } from 'lucide-react';

export function ThemeToggle({ className }: { className?: string }) {
  const [isDark, setIsDark] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    const stored = localStorage.getItem('theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const dark = stored === 'dark' || (!stored && prefersDark);
    setIsDark(dark);
    document.documentElement.classList.toggle('dark', dark);
  }, []);

  const toggleTheme = () => {
    const newDark = !isDark;
    setIsDark(newDark);
    localStorage.setItem('theme', newDark ? 'dark' : 'light');
    document.documentElement.classList.toggle('dark', newDark);
  };

  if (!mounted) return <div className={`w-9 h-9 rounded-lg ${className ?? ''}`} />;

  return (
    <button
      onClick={toggleTheme}
      className={`relative w-9 h-9 rounded-lg flex items-center justify-center transition-colors hover:bg-slate-100 dark:hover:bg-slate-700 ${className ?? ''}`}
      aria-label={`Switch to ${isDark ? 'light' : 'dark'} mode`}
    >
      <motion.div
        key={isDark ? 'moon' : 'sun'}
        initial={{ scale: 0.5, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.2, ease: 'easeInOut' }}
      >
        {isDark ? <Moon size={18} className="text-slate-300" /> : <Sun size={18} className="text-amber-500" />}
      </motion.div>
    </button>
  );
}
