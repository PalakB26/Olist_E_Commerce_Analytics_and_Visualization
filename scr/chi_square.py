from scipy.stats import chi2_contingency
# rows: on-time, late ; cols: 1-2 stars, 3-5 stars  — paste the Q6b numbers
table = [[8269, 80913], [3982, 2396]]
chi2, p, dof, _ = chi2_contingency(table)
rr = (table[1][0]/sum(table[1])) / (table[0][0]/sum(table[0]))
print(f"chi2={chi2:.0f}, p={p:.2e}, relative risk={rr:.1f}x")