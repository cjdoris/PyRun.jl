### A Pluto.jl notebook ###
# v0.19.9

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ aeaaff50-0445-11ed-0c89-1b9806eba170
using Pkg; Pkg.activate("pyrun", shared=true);

# ╔═╡ 2906eb99-6d54-46e7-b21d-425fd41da3b1
using PyRun, PlutoUI; pyrun("""
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import bokeh.plotting
from IPython.display import HTML
sns.set_theme()
""", locals=nothing)

# ╔═╡ daf50b9b-0269-49d0-acf7-8ec0610781c3
md"""
# Demo Notebook

A Pluto notebook demonstrating some features of PyRun.

It assumes you have a shared project called "pyrun" into which PyRun and CondaPkg are
installed, with the Conda packages numpy, bokeh, matplotlib, ipython and seaborn.
"""

# ╔═╡ 8c641957-2b47-496d-9179-82eb3ec5cc28
md"## Import PyRun and some Python modules"

# ╔═╡ 82596193-ccd7-4d94-8fc9-d448cdf81ba2
md"## Numpy arrays"

# ╔═╡ a0bd78fe-822b-4fe9-b0ee-dfe1ae516592
md"""
**nrows** $(@bind nrows Slider(1:10, default=3, show_value=true))

**ncols** $(@bind ncols Slider(1:10, default=4, show_value=true))
"""

# ╔═╡ 478409dc-07cf-4136-927d-070c6339cf6f
pyrun("""
x = np.random.randn(nrows, ncols)
jl.ret(x)
""", locals=(; nrows, ncols))

# ╔═╡ 117a33ec-2cb3-4e08-b45e-f10f345d843b
md"## Rich media, such as HTML..."

# ╔═╡ 4a714d4c-1bd6-4ffb-a98b-d5fc814aea97
md"""
**coolness** $(@bind coolness Select(["cool", "coooool", "very cool", "awesome"]))

**lang** $(@bind lang Select(["Python", "Julia"]))
"""

# ╔═╡ ee65a30b-9064-4fff-ad96-c641ef4d2e88
pyrun("""
html = HTML(f'<p>This is some <em>{coolness}</em> HTML from <b>{lang}</b>!</p>')
jl.ret(html, 'html')
""", locals=(; coolness, lang))

# ╔═╡ 8687286d-70f3-4325-b215-747bbff19941
md"## ... and MatPlotLib"

# ╔═╡ e6e470af-118e-4aa4-9779-30ae33a4ed37
md"""
**nlines** $(@bind nlines Slider(1:10, default=4))
"""

# ╔═╡ fbb36c27-d962-4f34-bec8-6f1e4ee01004
pyrun("""
for i in range(nlines):
	plt.plot(np.cumsum(np.random.randn(1000)), label=f"Line {i}")
plt.legend()
plt.xlabel("Time (days)")
plt.ylabel("Profit (million USD)")
jl.ret(plt.gcf(), 'png')
""", locals=(; nlines))

# ╔═╡ 22f03626-45db-4d7c-9b5a-4a191e57b2f4
md"# ... and Seaborn"

# ╔═╡ df5d5392-801f-4076-9dbc-c9295d18bfca
md"""
**format** $(@bind fmt Select(["svg", "png"]))
"""

# ╔═╡ 9f354afd-c585-448a-ac57-5dcee5d12f69
pyrun("""
# Load an example dataset
tips = sns.load_dataset("tips")

# Create a visualization
plot = sns.relplot(
    data=tips,
    x="total_bill", y="tip", col="time",
    hue="smoker", style="smoker", size="size",
)

jl.ret(plot, fmt)
""", locals=(; fmt))

# ╔═╡ 1cbd65d1-4b8a-444f-8c11-ddf68c8ac43d
md"## ... and Bokeh"

# ╔═╡ 24a2abbd-08cc-4e22-94b4-894ae369d852
pyrun("""
# prepare some data
x = [1, 2, 3, 4, 5]
y = [6, 7, 2, 4, 5]

# create a new plot with a title and axis labels
p = bokeh.plotting.figure(title="Simple line example", x_axis_label="x", y_axis_label="y")

# add a line renderer with legend and line thickness
p.line(x, y, legend_label="Temp.", line_width=2)

# show the results
jl.ret(p, 'html')
""")

# ╔═╡ Cell order:
# ╟─daf50b9b-0269-49d0-acf7-8ec0610781c3
# ╠═aeaaff50-0445-11ed-0c89-1b9806eba170
# ╟─8c641957-2b47-496d-9179-82eb3ec5cc28
# ╠═2906eb99-6d54-46e7-b21d-425fd41da3b1
# ╟─82596193-ccd7-4d94-8fc9-d448cdf81ba2
# ╟─a0bd78fe-822b-4fe9-b0ee-dfe1ae516592
# ╠═478409dc-07cf-4136-927d-070c6339cf6f
# ╟─117a33ec-2cb3-4e08-b45e-f10f345d843b
# ╟─4a714d4c-1bd6-4ffb-a98b-d5fc814aea97
# ╠═ee65a30b-9064-4fff-ad96-c641ef4d2e88
# ╟─8687286d-70f3-4325-b215-747bbff19941
# ╟─e6e470af-118e-4aa4-9779-30ae33a4ed37
# ╠═fbb36c27-d962-4f34-bec8-6f1e4ee01004
# ╟─22f03626-45db-4d7c-9b5a-4a191e57b2f4
# ╟─df5d5392-801f-4076-9dbc-c9295d18bfca
# ╠═9f354afd-c585-448a-ac57-5dcee5d12f69
# ╟─1cbd65d1-4b8a-444f-8c11-ddf68c8ac43d
# ╠═24a2abbd-08cc-4e22-94b4-894ae369d852
