def column_total(rows, index):
    values = [float(row[index] for row in rows]
    return sum(values)


def column_mean(rows, index):
    return column_total(rows, index) / len(rows)
