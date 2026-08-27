---
name: Alkek Scientific Research System
colors:
  surface: '#fbf9f8'
  surface-dim: '#dbdad9'
  surface-bright: '#fbf9f8'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f5f3f3'
  surface-container: '#efeded'
  surface-container-high: '#e9e8e7'
  surface-container-highest: '#e4e2e2'
  on-surface: '#1b1c1c'
  on-surface-variant: '#454651'
  inverse-surface: '#303031'
  inverse-on-surface: '#f2f0f0'
  outline: '#757682'
  outline-variant: '#c5c5d3'
  surface-tint: '#4559a8'
  primary: '#000c3d'
  on-primary: '#ffffff'
  primary-container: '#001d6e'
  on-primary-container: '#7689dc'
  inverse-primary: '#b8c4ff'
  secondary: '#006874'
  on-secondary: '#ffffff'
  secondary-container: '#94edfc'
  on-secondary-container: '#006d79'
  tertiary: '#001031'
  on-tertiary: '#ffffff'
  tertiary-container: '#00245a'
  on-tertiary-container: '#4d8aff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dde1ff'
  primary-fixed-dim: '#b8c4ff'
  on-primary-fixed: '#001453'
  on-primary-fixed-variant: '#2c408f'
  secondary-fixed: '#97f0ff'
  secondary-fixed-dim: '#7ad4e2'
  on-secondary-fixed: '#001f24'
  on-secondary-fixed-variant: '#004f57'
  tertiary-fixed: '#d9e2ff'
  tertiary-fixed-dim: '#afc6ff'
  on-tertiary-fixed: '#001944'
  on-tertiary-fixed-variant: '#004299'
  background: '#fbf9f8'
  on-background: '#1b1c1c'
  surface-variant: '#e4e2e2'
  bio-growth: '#10B981'
  warning-amber: '#F59E0B'
  error-red: '#EF4444'
  surface-bg-light: '#EEFBF9'
  surface-bg-dark: '#0D1117'
typography:
  headline-xl:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 16px
  code-md:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
  code-sm:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 14px
  label-caps:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 12px
    letterSpacing: 0.05em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  margin-page: 24px
  gutter-grid: 16px
  padding-card: 16px
  padding-dense: 8px
---

## Brand & Style

The design system is engineered for the **Alkek Center for Metagenomics and Microbiome Research**. It prioritizes high information density, empirical clarity, and functional efficiency for a specialized audience of bioinformaticians and researchers. 

The design style is **Corporate / Modern** with a **Technical** edge. It utilizes a structured, systematic approach to interface design, where every pixel serves a data-driven purpose. The aesthetic is "Lab-Grade"—clean, sterile but sophisticated, and highly structured, evoking the precision of medical instrumentation and genomic sequencing.

### Design Principles:
- **Data-First Hierarchy:** Visual flair is secondary to the legibility of complex datasets and taxonomic visualizations.
- **Institutional Authority:** Leverages deep blues and crisp whites to maintain the professional prestige of Baylor College of Medicine.
- **Functional Density:** Optimized for widescreen laboratory monitors, allowing for high-density information layouts without cognitive overload.

## Colors

The palette is anchored by "Baylor Deep Blue," providing a stable, institutional foundation. 

### Implementation Guidelines:
- **Primary Blue (#001D6E):** Used for primary navigation, headers, and key call-to-action buttons.
- **Secondary Teal (#007A87):** Used for "Biological/Growth" metaphors, progress indicators, and success states in metagenomic reporting.
- **Tech Blue (#1F6FEB):** Reserved for interactive elements, links, and code-based UI components to differentiate from institutional branding.
- **Semantic Colors:** 
    - **Emerald:** Positive sequencing results, completed status.
    - **Amber:** Pending processes, quality control warnings.
    - **Red:** Failed runs or critical taxonomic anomalies.
- **Neutral/Surface:** In light mode, `#EEFBF9` provides a cool, clinical background. In dark mode, use a deep slate (`#0D1117`) to reduce eye strain during long-form data analysis.

## Typography

This design system utilizes a dual-font strategy. **Inter** is the primary typeface for all UI elements and data labels, chosen for its exceptional legibility at small sizes and high x-height. **JetBrains Mono** is utilized for DNA sequences, file paths, and terminal outputs to ensure character-level distinction (important for identifying nucleotide variations).

### Usage Notes:
- **Headlines:** Use tight letter-spacing and bold weights to anchor page sections.
- **Data Density:** Body-sm (12px) is the workhorse for table data and metadata sidebars.
- **Monospace:** Use exclusively for genomic strings, IDs (e.g., Sample ID: ALK-9921), and filenames.

## Layout & Spacing

The layout utilizes a **Fixed-Fluid Hybrid Grid**. Sidebars and metadata panels are fixed-width (280px and 320px respectively), while the central visualization area is fluid to accommodate complex charts.

### Layout Principles:
- **4px Base Unit:** All spacing and sizing must be multiples of 4px.
- **Data-Dense Padding:** Standard padding for research cards is 16px, but nested data tables use "Dense" 8px padding to maximize vertical information display.
- **Breakpoints:** 
    - **Desktop (1440px+):** 3-pane view (Navigation, Main Stage, Metadata Inspector).
    - **Tablet (1024px):** 2-pane view (Navigation collapses to icons, Main Stage + Metadata).
    - **Mobile:** Not prioritized, but follows a single-stack vertical flow for report viewing.

## Elevation & Depth

To maintain a "Clinical" feel, this design system avoids heavy drop shadows. Depth is communicated through **Tonal Layers** and **Low-Contrast Outlines**.

- **Surface Levels:** 
    - **Level 0 (Background):** Primary background color (`#EEFBF9` in light mode).
    - **Level 1 (Cards):** Pure white or dark-grey surfaces with a 1px border (`#E2E8F0` or `#30363D`).
    - **Level 2 (Modals/Popovers):** Subtle 8px blur shadow with 5% opacity to indicate temporary focus.
- **Active States:** Elements being edited or "Processing" use a subtle blue inner glow or a secondary-color 2px border rather than increasing elevation.

## Shapes

The shape language is **Soft (0.25rem)**. This provides a professional, modern look without the "playfulness" of highly rounded corners. 

- **Primary UI Elements:** Buttons, inputs, and cards use the standard 4px (0.25rem) radius.
- **Status Badges:** Use "Pill-shaped" (1rem+) rounding to clearly distinguish them from interactive buttons.
- **Data Visualization Containers:** Should maintain sharp or very slightly rounded edges to maximize internal drawing area for charts.

## Components

### Buttons & Actions
- **Primary:** Filled Blue (#001D6E), white text. Used for "Run Analysis" or "Submit."
- **Secondary:** Outlined Blue, for "Export" or "Filter."
- **Ghost:** For sidebar navigation and minor actions.
- **File Actions:** Use small, 28px square icon buttons for quick actions (Download, Delete, View Raw).

### Status Badges
- **Processing:** Pulsing Teal dot + text.
- **Completed:** Emerald background (10% opacity) + Emerald text.
- **Expired/Failed:** Red background (10% opacity) + Red text.

### Data Cards & Iframe Containers
- **Research Cards:** White background, 1px neutral border, headline in Inter-Bold.
- **Iframe Wrappers:** External reports (e.g., MultiQC) should be contained in a "Window" style component with a gray header bar clearly indicating it is an external source.

### Input Fields
- **Search:** Persistent search bar in top navigation with a `Cmd+K` indicator.
- **Filters:** Multi-select chips for taxonomic levels (Kingdom, Phylum, Class, etc.).

### Navigation
- **Sidebar:** Dark primary background with high-contrast active states. Supports hierarchical folders for deep project structures.
- **Breadcrumbs:** Critical for deep file navigation; always visible below the main header.