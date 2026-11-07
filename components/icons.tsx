import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement>;

function base(props: IconProps) {
  return {
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.5,
    "aria-hidden": true,
    ...props,
  };
}

export function IconOverview(props: IconProps) {
  return (
    <svg {...base(props)}>
      <rect x="3.5" y="3.5" width="7" height="7" rx="1.5" />
      <rect x="13.5" y="3.5" width="7" height="7" rx="1.5" />
      <rect x="3.5" y="13.5" width="7" height="7" rx="1.5" />
      <rect x="13.5" y="13.5" width="7" height="7" rx="1.5" />
    </svg>
  );
}

export function IconServer(props: IconProps) {
  return (
    <svg {...base(props)}>
      <rect x="3.5" y="4" width="17" height="6" rx="1.5" />
      <rect x="3.5" y="14" width="17" height="6" rx="1.5" />
      <path d="M7 7h.01M7 17h.01" strokeLinecap="round" />
    </svg>
  );
}

export function IconDevice(props: IconProps) {
  return (
    <svg {...base(props)}>
      <rect x="4" y="4.5" width="16" height="11" rx="1.5" />
      <path d="M8 19.5h8" strokeLinecap="round" />
    </svg>
  );
}

export function IconPhone(props: IconProps) {
  return (
    <svg {...base(props)}>
      <rect x="7.5" y="3.5" width="9" height="17" rx="2" />
      <path d="M11 17.5h2" strokeLinecap="round" />
    </svg>
  );
}

export function IconTablet(props: IconProps) {
  return (
    <svg {...base(props)}>
      <rect x="5.5" y="3.5" width="13" height="17" rx="2" />
      <path d="M11 17.5h2" strokeLinecap="round" />
    </svg>
  );
}

export function IconConfig(props: IconProps) {
  return (
    <svg {...base(props)}>
      <path d="M8 7V5.5A1.5 1.5 0 0 1 9.5 4h5A1.5 1.5 0 0 1 16 5.5V7" />
      <rect x="4.5" y="7" width="15" height="13" rx="1.5" />
      <path d="M9 12h6M9 16h4" strokeLinecap="round" />
    </svg>
  );
}

export function DeviceIcon({ name, ...props }: IconProps & { name: string }) {
  const normalized = name.toLowerCase();
  if (normalized.includes("телефон")) return <IconPhone {...props} />;
  if (normalized.includes("планшет")) return <IconTablet {...props} />;
  return <IconDevice {...props} />;
}

export function IconSettings(props: IconProps) {
  return (
    <svg {...base(props)}>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3.5v2.2M12 18.3v2.2M4.8 6.8l1.6 1.6M17.6 15.6l1.6 1.6M3.5 12h2.2M18.3 12h2.2M4.8 17.2l1.6-1.6M17.6 8.4l1.6-1.6" strokeLinecap="round" />
    </svg>
  );
}
