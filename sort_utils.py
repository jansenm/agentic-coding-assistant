"""Sorting helpers (throwaway scratch code for the agent to improve)."""

def quicksort(items):
    if len(items) <= 1:
        return items
    pivot = items[0]
    less = [x for x in items[1:] if x < pivot]
    greater = [x for x in items if x > pivot]
    return quicksort(less) + [pivot] + quicksort(greater)

def median_pivot(items):
    """Pick a better pivot: median of first, middle, last."""
    # TODO: implement me - currently unused
    raise NotImplementedError
