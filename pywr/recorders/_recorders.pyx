import numpy as np
cimport numpy as np
import pandas as pd
import warnings
from past.builtins import basestring

recorder_registry = {}

cdef enum AggFuncs:
    SUM = 0
    MIN = 1
    MAX = 2
    MEAN = 3
    MEDIAN = 4
    PRODUCT = 5
    CUSTOM = 6
_agg_func_lookup = {
    "sum": AggFuncs.SUM,
    "min": AggFuncs.MIN,
    "max": AggFuncs.MAX,
    "mean": AggFuncs.MEAN,
    "median": AggFuncs.MEDIAN,
    "product": AggFuncs.PRODUCT,
    "custom": AggFuncs.CUSTOM,
}

cdef enum ObjDirection:
    NONE = 0
    MAXIMISE = 1
    MINIMISE = 2
_obj_direction_lookup = {
    "maximize": ObjDirection.MAXIMISE,
    "maximise": ObjDirection.MAXIMISE,
    "max": ObjDirection.MAXIMISE,
    "minimise": ObjDirection.MINIMISE,
    "minimize": ObjDirection.MINIMISE,
    "min": ObjDirection.MINIMISE,
}

cdef class Aggregator:
    """Utility class for computing aggregate values."""
    def __init__(self, func):
        self.func = func

    property func:
        def __set__(self, func):
            self._user_func = None
            if isinstance(func, basestring):
                func = _agg_func_lookup[func.lower()]
            elif callable(func):
                self._user_func = func
                func = AggFuncs.CUSTOM
            else:
                raise ValueError("Unrecognised aggregation function: \"{}\".".format(func))
            self._func = func

    cpdef double aggregate_1d(self, double[:] data, ignore_nan=False) except *:
        """Compute an aggregated value across 1D array.
        """
        cdef double[:] values = data

        if ignore_nan:
            values = np.array(values)[~np.isnan(values)]

        if self._func == AggFuncs.PRODUCT:
            return np.product(values)
        elif self._func == AggFuncs.SUM:
            return np.sum(values)
        elif self._func == AggFuncs.MAX:
            return np.max(values)
        elif self._func == AggFuncs.MIN:
            return np.min(values)
        elif self._func == AggFuncs.MEAN:
            return np.mean(values)
        elif self._func == AggFuncs.MEDIAN:
            return np.median(values)
        elif self._func == AggFuncs.CUSTOM:
            return self._user_func(np.array(values))
        else:
            raise ValueError('Aggregation function code "{}" not recognised.'.format(self._func))

    cpdef double[:] aggregate_2d(self, double[:, :] data, axis=0, ignore_nan=False) except *:
        """Compute an aggregated value along an axis of a 2D array.
        """
        cdef double[:, :] values = data

        if ignore_nan:
            values = np.array(values)[~np.isnan(values)]

        if self._func == AggFuncs.PRODUCT:
            return np.product(values, axis=axis)
        elif self._func == AggFuncs.SUM:
            return np.sum(values, axis=axis)
        elif self._func == AggFuncs.MAX:
            return np.max(values, axis=axis)
        elif self._func == AggFuncs.MIN:
            return np.min(values, axis=axis)
        elif self._func == AggFuncs.MEAN:
            return np.mean(values, axis=axis)
        elif self._func == AggFuncs.MEDIAN:
            return np.median(values, axis=axis)
        elif self._func == AggFuncs.CUSTOM:
            return self._user_func(np.array(values), axis=axis)
        else:
            raise ValueError('Aggregation function code "{}" not recognised.'.format(self._func))


cdef class Recorder(Component):
    """Base class for recording information from a `pywr.model.Model`.

    Recorder components are used to calculate, aggregate and save data from a simulation. This
    base class provides the basic functionality for all recorders.

    Parameters
    ==========
    model : `pywr.core.Model`
    agg_func : str or callable (default="mean")
        Scenario aggregation function to use when `aggregated_value` is called.
    name : str (default=None)
        Name of the recorder.
    comment : str (default=None)
        Comment or description of the recorder.
    ignore_nan : bool (default=False)
        Flag to ignore NaN values when calling `aggregated_value`.
    is_objective : {None, 'maximize', 'maximise', 'max', 'minimize', 'minimise', 'min'}
        Flag to denote the direction, if any, of optimisation undertaken with this recorder.
    is_constraint : bool (default=False)
        Flag to denote whether this recorder is to be used as a constraint during optimisation.
    epsilon : float (default=1.0)
        Epsilon distance used by some optimisation algorithms.
    """
    def __init__(self, model, agg_func="mean", ignore_nan=False, is_objective=None, epsilon=1.0,
                 is_constraint=False, name=None, **kwargs):
        if name is None:
            name = self.__class__.__name__.lower()
        super(Recorder, self).__init__(model, name=name, **kwargs)
        self.ignore_nan = ignore_nan
        self.is_objective = is_objective
        self.is_constraint = is_constraint
        self.epsilon = epsilon
        # Create the aggregator for scenarios
        self._scenario_aggregator = Aggregator(agg_func)

    property agg_func:
        def __set__(self, agg_func):
            self._scenario_aggregator.func = agg_func

    property is_objective:
        def __set__(self, value):
            if value is None:
                self._is_objective = ObjDirection.NONE
            else:
                self._is_objective = _obj_direction_lookup[value]
        def __get__(self):
            if self._is_objective == ObjDirection.NONE:
                return None
            elif self._is_objective == ObjDirection.MAXIMISE:
                return 'maximise'
            elif self._is_objective == ObjDirection.MINIMISE:
                return 'minimise'
            else:
                raise ValueError("Objective direction type not recognised.")


    def __repr__(self):
        return '<{} "{}">'.format(self.__class__.__name__, self.name)

    cpdef double aggregated_value(self) except? -1:
        cdef double[:] values = self.values()
        return self._scenario_aggregator.aggregate_1d(values)

    cpdef double[:] values(self):
        raise NotImplementedError()

    @classmethod
    def load(cls, model, data):
        try:
            node_name = data["node"]
        except KeyError:
            pass
        else:
            data["node"] = model._get_node_from_ref(model, node_name)
        return cls(model, **data)

    @classmethod
    def register(cls):
        recorder_registry[cls.__name__.lower()] = cls

    @classmethod
    def unregister(cls):
        del(recorder_registry[cls.__name__.lower()])

cdef class AggregatedRecorder(Recorder):
    """
    This Recorder is used to aggregate across multiple other Recorder objects.

    The class provides a method to produce a complex aggregated recorder by taking
    the results of other records. The `.values()` method first collects unaggregated values
    from the provided recorders. These are then aggregated on a per scenario basis and returned
    by this classes `.values()` method. This method allows `AggregatedRecorder` to be used as
    a recorder for in other `AggregatedRecorder` instances.

    By default the same `agg_func` function is used for both steps, but an optional
    `recorder_agg_func` can undertake a different aggregation across scenarios. For
    example summing recorders per scenario, and then taking a mean of the sum totals.

    Parameters
    ==========
    model : `pywr.core.Model`
    recorders: iterable of `Recorder` objects.
        The other `Recorder` instances to perform aggregation over.
    agg_func : str or callable, optional
        Scenario aggregation function to use when `aggregated_value` is called (default="mean").
    recorder_agg_func : str or callable, optional
        Recorder aggregation function to use when `aggregated_value` is called (default=`agg_func`).
    """
    def __init__(self, model, recorders, **kwargs):
        # Optional different method for aggregating across self.recorders scenarios
        agg_func = kwargs.pop('recorder_agg_func', kwargs.get('agg_func'))

        if isinstance(agg_func, basestring):
            agg_func = _agg_func_lookup[agg_func.lower()]
        elif callable(agg_func):
            self.recorder_agg_func = agg_func
            agg_func = AggFuncs.CUSTOM
        else:
            raise ValueError("Unrecognised recorder aggregation function: \"{}\".".format(agg_func))
        self._recorder_agg_func = agg_func

        super(AggregatedRecorder, self).__init__(model, **kwargs)
        self.recorders = list(recorders)

        for rec in self.recorders:
            self.children.add(rec)

    cpdef double[:] values(self):
        cdef Recorder recorder
        cdef double[:] value, value2
        assert(len(self.recorders))
        cdef int n = len(self.model.scenarios.combinations)
        cdef int i

        if self._recorder_agg_func == AggFuncs.PRODUCT:
            value = np.ones(n, np.float64)
            for recorder in self.recorders:
                value2 = recorder.values()
                for i in range(n):
                    value[i] *= value2[i]
        elif self._recorder_agg_func == AggFuncs.SUM:
            value = np.zeros(n, np.float64)
            for recorder in self.recorders:
                value2 = recorder.values()
                for i in range(n):
                    value[i] += value2[i]
        elif self._recorder_agg_func == AggFuncs.MAX:
            value = np.empty(n)
            value[:] = np.NINF
            for recorder in self.recorders:
                value2 = recorder.values()
                for i in range(n):
                    if value2[i] > value[i]:
                        value[i] = value2[i]
        elif self._recorder_agg_func == AggFuncs.MIN:
            value = np.empty(n)
            value[:] = np.PINF
            for recorder in self.recorders:
                value2 = recorder.values()
                for i in range(n):
                    if value2[i] < value[i]:
                        value[i] = value2[i]
        elif self._recorder_agg_func == AggFuncs.MEAN:
            value = np.zeros(n, np.float64)
            for recorder in self.recorders:
                value2 = recorder.values()
                for i in range(n):
                    value[i] += value2[i]
            for i in range(n):
                value[i] /= len(self.recorders)
        else:
            value = self.recorder_agg_func([recorder.values() for recorder in self.recorders], axis=0)
        return value

    @classmethod
    def load(cls, model, data):
        recorder_names = data["recorders"]
        recorders = [model.recorders[name] for name in recorder_names]
        del(data["recorders"])
        rec = cls(model, recorders, **data)

AggregatedRecorder.register()


cdef class NodeRecorder(Recorder):
    def __init__(self, model, AbstractNode node, name=None, **kwargs):
        if name is None:
            name = "{}.{}".format(self.__class__.__name__.lower(), node.name)
        super(NodeRecorder, self).__init__(model, name=name, **kwargs)
        self._node = node
        node._recorders.append(self)

    cpdef double[:] values(self):
        return self._node._flow

    property node:
        def __get__(self):
            return self._node

    def __repr__(self):
        return '<{} on {} "{}">'.format(self.__class__.__name__, self.node, self.name)

NodeRecorder.register()


cdef class StorageRecorder(Recorder):
    def __init__(self, model, AbstractStorage node, name=None, **kwargs):
        if name is None:
            name = "{}.{}".format(self.__class__.__name__.lower(), node.name)
        super(StorageRecorder, self).__init__(model, name=name, **kwargs)
        self._node = node
        node._recorders.append(self)

    cpdef double[:] values(self):
        return self._node._volume

    property node:
        def __get__(self):
            return self._node

    def __repr__(self):
        return '<{} on {} "{}">'.format(self.__class__.__name__, self.node, self.name)

StorageRecorder.register()


cdef class ParameterRecorder(Recorder):
    """Base class for recorders that track `Parameter` values.

    Parameters
    ----------
    model : `pywr.core.Model`
    param : `pywr.parameters.Parameter`
        The parameter to record.
    name : str (optional)
        The name of the recorder
    """
    def __init__(self, model, Parameter param, name=None, **kwargs):
        if name is None:
            name = "{}.{}".format(self.__class__.__name__.lower(), param.name)
        super(ParameterRecorder, self).__init__(model, name=name, **kwargs)
        self._param = param
        param.parents.add(self)

    property parameter:
        def __get__(self):
            return self._param

    def __repr__(self):
        return '<{} on {} "{}" ({})>'.format(self.__class__.__name__, repr(self.parameter), self.name, hex(id(self)))

    def __str__(self):
        return '<{} on {} "{}">'.format(self.__class__.__name__, self.parameter, self.name)

    @classmethod
    def load(cls, model, data):
        # when the parameter being recorder is defined inline (i.e. not in the
        # parameters section, but within the node) we need to make sure the
        # node has been loaded first
        try:
            node_name = data["node"]
        except KeyError:
            node = None
        else:
            del(data["node"])
            node = model._get_node_from_ref(model, node_name)
        from pywr.parameters import load_parameter
        parameter = load_parameter(model, data.pop("parameter"))
        return cls(model, parameter, **data)

ParameterRecorder.register()


cdef class IndexParameterRecorder(Recorder):
    def __init__(self, model, IndexParameter param, name=None, **kwargs):
        if name is None:
            name = "{}.{}".format(self.__class__.__name__.lower(), param.name)
        super(IndexParameterRecorder, self).__init__(model, name=name, **kwargs)
        self._param = param
        param.parents.add(self)

    property parameter:
        def __get__(self):
            return self._param

    def __repr__(self):
        return '<{} on {} "{}" ({})>'.format(self.__class__.__name__, repr(self.parameter), self.name, hex(id(self)))

    def __str__(self):
        return '<{} on {} "{}">'.format(self.__class__.__name__, self.parameter, self.name)

    @classmethod
    def load(cls, model, data):
        from pywr.parameters import load_parameter
        parameter = load_parameter(model, data.pop("parameter"))
        return cls(model, parameter, **data)

IndexParameterRecorder.register()


cdef class NumpyArrayNodeRecorder(NodeRecorder):
    """Recorder for timeseries information from a `Node`.

    This class stores flow from a specific node for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        Node instance to record.
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    def __init__(self, model, AbstractNode node, **kwargs):
        # Optional different method for aggregating across time.
        temporal_agg_func = kwargs.pop('temporal_agg_func', 'mean')
        super(NumpyArrayNodeRecorder, self).__init__(model, node, **kwargs)
        self._temporal_aggregator = Aggregator(temporal_agg_func)

    property temporal_agg_func:
        def __set__(self, agg_func):
            self._temporal_aggregator.func = agg_func

    cpdef setup(self):
        cdef int ncomb = len(self.model.scenarios.combinations)
        cdef int nts = len(self.model.timestepper)
        self._data = np.zeros((nts, ncomb))

    cpdef reset(self):
        self._data[:, :] = 0.0

    cpdef after(self):
        cdef int i
        cdef Timestep ts = self.model.timestepper.current
        for i in range(self._data.shape[1]):
            self._data[ts._index,i] = self._node._flow[i]
        return 0

    property data:
        def __get__(self, ):
            return np.array(self._data)
        
    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._data, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data

        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=np.array(self._data), index=index, columns=sc_index)

NumpyArrayNodeRecorder.register()



cdef class FlowDurationCurveRecorder(NumpyArrayNodeRecorder):
    """
    This recorder calculates a flow duration curve for each scenario.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        The node to record
    percentiles : array
        The percentiles to use in the calculation of the flow duration curve.
        Values must be in the range 0-100.
    agg_func: str, optional
        function used for aggregating the FDC across percentiles.
        Numpy style functions that support an axis argument are supported.
    fdc_agg_func: str, optional
        optional different function for aggregating across scenarios.
    """
    def __init__(self, model, AbstractNode node, percentiles, **kwargs):

        # Optional different method for aggregating across percentiles
        if 'fdc_agg_func' in kwargs:
            # Support previous behaviour
            warnings.warn('The "fdc_agg_func" key is deprecated for defining the temporal '
                          'aggregation in {}. Please "temporal_agg_func" instead.'
                          .format(self.__class__.__name__))
            if "temporal_agg_func" in kwargs:
                raise ValueError('Both "fdc_agg_func" and "temporal_agg_func" keywords given.'
                                 'This is ambiguous. Please use "temporal_agg_func" only.')
            kwargs["temporal_agg_func"] = kwargs.pop("fdc_agg_func")

        super(FlowDurationCurveRecorder, self).__init__(model, node, **kwargs)
        self._percentiles = np.asarray(percentiles, dtype=np.float64)

    cpdef finish(self):
        self._fdc = np.percentile(np.asarray(self._data), np.asarray(self._percentiles), axis=0)

    property fdc:
        def __get__(self, ):
            return np.array(self._fdc)

    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._fdc, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data

        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self._percentiles
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=np.array(self.fdc), index=index, columns=sc_index)

FlowDurationCurveRecorder.register()


cdef class SeasonalFlowDurationCurveRecorder(FlowDurationCurveRecorder):
    """
    This recorder calculates a flow duration curve for each scenario for a given season
    specified in months.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        The node to record
    percentiles : array
        The percentiles to use in the calculation of the flow duration curve.
        Values must be in the range 0-100.
    agg_func: str, optional
        function used for aggregating the FDC across percentiles.
        Numpy style functions that support an axis argument are supported.
    fdc_agg_func: str, optional
        optional different function for aggregating across scenarios.
    months: array
        The numeric values of the months the flow duration curve should be calculated for. 
    """

    def __init__(self, model, AbstractNode node, percentiles, months, **kwargs):
        super(SeasonalFlowDurationCurveRecorder, self).__init__(model, node, percentiles, **kwargs)
        self._months = set(months)
    
    cpdef finish(self):
        # this is a def method rather than cpdef because closures inside cpdef functions are not supported yet.        
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex

        df = pd.DataFrame(data=np.array(self._data), index=index, columns=sc_index)        
        mask = np.asarray(df.index.map(self.is_season))
        self._fdc = np.percentile(df.loc[mask, :], np.asarray(self._percentiles), axis=0)

    def is_season(self, x):
        return x.month in self._months

SeasonalFlowDurationCurveRecorder.register()

cdef class FlowDurationCurveDeviationRecorder(FlowDurationCurveRecorder):
    """
    This recorder calculates a Flow Duration Curve (FDC) for each scenario and then
    calculates their deviation from upper and lower target FDCs. The 2nd dimension of the target
    duration curves and percentiles list must be of the same length and have the same
    order (high to low values or low to high values).
    
    Deviation is calculated as positive if actual FDC is above the upper target or below the lower
    target. If actual FDC falls between the upper and lower targets zero deviation is returned.    
    
    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        The node to record
    percentiles : array
        The percentiles to use in the calculation of the flow duration curve.
        Values must be in the range 0-100.
    lower_target_fdc : array
        The lower FDC against which the scenario FDCs are compared
    upper_target_fdc : array
        The upper FDC against which the scenario FDCs are compared        
    agg_func: str, optional
        Function used for aggregating the FDC deviations across percentiles.
        Numpy style functions that support an axis argument are supported.
    fdc_agg_func: str, optional
        Optional different function for aggregating across scenarios.

    """
    def __init__(self, model, AbstractNode node, percentiles, lower_target_fdc, upper_target_fdc, scenario=None, **kwargs):
        super(FlowDurationCurveDeviationRecorder, self).__init__(model, node, percentiles, **kwargs)

        lower_target = np.array(lower_target_fdc, dtype=np.float64)
        if lower_target.ndim < 2:
            lower_target = lower_target[:, np.newaxis]

        upper_target = np.array(upper_target_fdc, dtype=np.float64)
        if upper_target.ndim < 2:
            upper_target = upper_target[:, np.newaxis]

        self._lower_target_fdc = lower_target
        self._upper_target_fdc = upper_target
        self.scenario = scenario
        if len(self._percentiles) != self._lower_target_fdc.shape[0]:
            raise ValueError("The lengths of the lower target FDC and the percentiles list do not match")
        if len(self._percentiles) != self._upper_target_fdc.shape[0]:
            raise ValueError("The lengths of the upper target FDC and the percentiles list do not match")

    cpdef setup(self):
        super(FlowDurationCurveDeviationRecorder, self).setup()
        # Check target FDC is the correct size; this is done in setup rather than __init__
        # because the scenarios might change after the Recorder is created.
        if self.scenario is not None:
            if self._lower_target_fdc.shape[1] != self.scenario.size:
                raise ValueError('The number of lower target FDCs does not match the size ({}) of scenario "{}"'.format(self.scenario.size, self.scenario.name))
            if self._upper_target_fdc.shape[1] != self.scenario.size:
                raise ValueError('The number of upper target FDCs does not match the size ({}) of scenario "{}"'.format(self.scenario.size, self.scenario.name))
        else:
            if self._lower_target_fdc.shape[1] > 1 and \
                    self._lower_target_fdc.shape[1] != len(self.model.scenarios.combinations):
                raise ValueError("The number of lower target FDCs does not match the number of scenarios")
            if self._upper_target_fdc.shape[1] > 1 and \
                    self._upper_target_fdc.shape[1] != len(self.model.scenarios.combinations):
                raise ValueError("The number of upper target FDCs does not match the number of scenarios")

    cpdef finish(self):
        super(FlowDurationCurveDeviationRecorder, self).finish()

        cdef int i, j, jl, ju, k, sc_index
        cdef ScenarioIndex scenario_index
        cdef double[:] utrgt_fdc, ltrgt_fdc
        cdef double udev, ldev

        # We have to do this the slow way by iterating through all scenario combinations
        if self.scenario is not None:
            sc_index = self.model.scenarios.get_scenario_index(self.scenario)

        self._fdc_deviations = np.empty((self._lower_target_fdc.shape[0], len(self.model.scenarios.combinations)), dtype=np.float64)
        for i, scenario_index in enumerate(self.model.scenarios.combinations):

            if self.scenario is not None:
                # Get the scenario specific ensemble id for this combination
                j = scenario_index._indices[sc_index]
            else:
                j = scenario_index.global_id

            if self._lower_target_fdc.shape[1] == 1:
                jl = 0
            else:
                jl = j

            if self._upper_target_fdc.shape[1] == 1:
                ju = 0
            else:
                ju = j

            # Cache the target FDC to use in this combination
            ltrgt_fdc = self._lower_target_fdc[:, jl]
            utrgt_fdc = self._upper_target_fdc[:, ju]
            # Finally calculate deviation
            for k in range(ltrgt_fdc.shape[0]):
                try:
                    # upper deviation (+ve when flow higher than upper target)
                    udev = (self._fdc[k, i] - utrgt_fdc[k])  / utrgt_fdc[k]
                    # lower deviation (+ve when flow less than lower target)
                    ldev = (ltrgt_fdc[k] - self._fdc[k, i])  / ltrgt_fdc[k]
                    # Overall deviation is the worst of upper and lower, but if both
                    # are negative (i.e. FDC is between upper and lower) there is zero deviation
                    self._fdc_deviations[k, i] = max(udev, ldev, 0.0)
                except ZeroDivisionError:
                    self._fdc_deviations[k, i] = np.nan

    property fdc_deviations:
        def __get__(self, ):
            return np.array(self._fdc_deviations)


    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._fdc_deviations, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self, return_fdc=False):
        """ Return a `pandas.DataFrame` of the deviations from the target FDCs
                
        Parameters
        ----------
        return_fdc : bool (default=False)
            If true returns a tuple of two dataframes. The first is the deviations, the second
            is the actual FDC.
        """
        index = self._percentiles
        sc_index = self.model.scenarios.multiindex

        df = pd.DataFrame(data=np.array(self._fdc_deviations), index=index, columns=sc_index)
        if return_fdc:
            return df, super(FlowDurationCurveDeviationRecorder, self).to_dataframe()
        else:
            return df

FlowDurationCurveDeviationRecorder.register()


cdef class NumpyArrayAbstractStorageRecorder(StorageRecorder):
    def __init__(self, model, AbstractStorage node, **kwargs):
        # Optional different method for aggregating across time.
        temporal_agg_func = kwargs.pop('temporal_agg_func', 'mean')
        super().__init__(model, node, **kwargs)

        self._temporal_aggregator = Aggregator(temporal_agg_func)

    property temporal_agg_func:
        def __set__(self, agg_func):
            self._temporal_aggregator.func = agg_func

    cpdef setup(self):
        cdef int ncomb = len(self.model.scenarios.combinations)
        cdef int nts = len(self.model.timestepper)
        self._data = np.zeros((nts, ncomb))

    cpdef reset(self):
        self._data[:, :] = 0.0

    cpdef after(self):
        raise NotImplementedError()

    property data:
        def __get__(self, ):
            return np.array(self._data)

    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._data, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data

        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=np.array(self._data), index=index, columns=sc_index)


cdef class NumpyArrayStorageRecorder(NumpyArrayAbstractStorageRecorder):
    """Recorder for timeseries information from a `Storage` node.

    This class stores volume from a specific node for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        Node instance to record.
    proportional : bool
        Whether to record proportional [0, 1.0] or absolute storage volumes (default=False).
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    def __init__(self, *args, **kwargs):
        # Optional different method for aggregating across time.
        self.proportional = kwargs.pop('proportional', False)
        super().__init__(*args, **kwargs)

    cpdef after(self):
        cdef int i
        cdef Timestep ts = self.model.timestepper.current
        for i in range(self._data.shape[1]):
            if self.proportional:
                self._data[ts._index,i] = self._node._current_pc[i]
            else:
                self._data[ts._index,i] = self._node._volume[i]
        return 0
NumpyArrayStorageRecorder.register()


cdef class StorageDurationCurveRecorder(NumpyArrayStorageRecorder):
    """
    This recorder calculates a storage duration curve for each scenario.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.AbstractStorage`
        The node to record
    percentiles : array
        The percentiles to use in the calculation of the flow duration curve.
        Values must be in the range 0-100.
    agg_func: str, optional
        function used for aggregating the FDC across percentiles.
        Numpy style functions that support an axis argument are supported.
    sdc_agg_func: str, optional
        optional different function for aggregating across scenarios.

    """

    def __init__(self, model, AbstractStorage node, percentiles, **kwargs):

        if "sdc_agg_func" in kwargs:
            # Support previous behaviour
            warnings.warn('The "sdc_agg_func" key is deprecated for defining the temporal '
                          'aggregation in {}. Please "temporal_agg_func" instead.'
                          .format(self.__class__.__name__))
            if "temporal_agg_func" in kwargs:
                raise ValueError('Both "sdc_agg_func" and "temporal_agg_func" keywords given.'
                                 'This is ambiguous. Please use "temporal_agg_func" only.')
            kwargs["temporal_agg_func"] = kwargs.pop("sdc_agg_func")

        super(StorageDurationCurveRecorder, self).__init__(model, node, **kwargs)
        self._percentiles = np.asarray(percentiles, dtype=np.float64)


    cpdef finish(self):
        self._sdc = np.percentile(np.asarray(self._data), np.asarray(self._percentiles), axis=0)

    property sdc:
        def __get__(self, ):
            return np.array(self._sdc)

    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._sdc, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data

        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self._percentiles
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=self.sdc, index=index, columns=sc_index)

StorageDurationCurveRecorder.register()

cdef class NumpyArrayLevelRecorder(NumpyArrayAbstractStorageRecorder):
    """Recorder for level timeseries from a `Storage` node.

    This class stores level from a specific node for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        Node instance to record.
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    cpdef after(self):
        cdef int i
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        cdef Storage node = self._node
        for i, scenario_index in enumerate(self.model.scenarios.combinations):
            self._data[ts._index,i] = node.get_level(scenario_index)
        return 0
NumpyArrayLevelRecorder.register()


cdef class NumpyArrayAreaRecorder(NumpyArrayAbstractStorageRecorder):
    """Recorder for area timeseries from a `Storage` node.

    This class stores area from a specific node for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        Node instance to record.
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    cpdef after(self):
        cdef int i
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        cdef Storage node = self._node
        for i, scenario_index in enumerate(self.model.scenarios.combinations):
            self._data[ts._index,i] = node.get_area(scenario_index)
        return 0
NumpyArrayAreaRecorder.register()


cdef class NumpyArrayParameterRecorder(ParameterRecorder):
    """Recorder for timeseries information from a `Parameter`.

    This class stores the value from a specific `Parameter` for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    param : `pywr.parameters.Parameter`
        Parameter instance to record.
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    def __init__(self, model, Parameter param, **kwargs):
        # Optional different method for aggregating across time.
        temporal_agg_func = kwargs.pop('temporal_agg_func', 'mean')
        super(NumpyArrayParameterRecorder, self).__init__(model, param, **kwargs)

        self._temporal_aggregator = Aggregator(temporal_agg_func)

    property temporal_agg_func:
        def __set__(self, agg_func):
            self._temporal_aggregator.func = agg_func

    cpdef setup(self):
        cdef int ncomb = len(self.model.scenarios.combinations)
        cdef int nts = len(self.model.timestepper)
        self._data = np.zeros((nts, ncomb))

    cpdef reset(self):
        self._data[:, :] = 0.0

    cpdef after(self):
        cdef int i
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        self._data[ts._index, :] = self._param.get_all_values()
        return 0

    property data:
        def __get__(self, ):
            return np.array(self._data)

    cpdef double[:] values(self):
        """Compute a value for each scenario using `temporal_agg_func`.
        """
        return self._temporal_aggregator.aggregate_2d(self._data, axis=0, ignore_nan=self.ignore_nan)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data
        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=np.array(self._data), index=index, columns=sc_index)
NumpyArrayParameterRecorder.register()


cdef class NumpyArrayIndexParameterRecorder(IndexParameterRecorder):
    """Recorder for timeseries information from an `IndexParameter`.

    This class stores the value from a specific `IndexParameter` for each time-step of a simulation. The
    data is saved internally using a memory view. The data can be accessed through the `data`
    attribute or `to_dataframe()` method.

    Parameters
    ----------
    model : `pywr.core.Model`
    param : `pywr.parameters.IndexParameter`
        Parameter instance to record.
    temporal_agg_func : str or callable (default="mean")
        Aggregation function used over time when computing a value per scenario. This can be used
        to return, for example, the median flow over a simulation. For aggregation over scenarios
        see the `agg_func` keyword argument.
    """
    def __init__(self, model, IndexParameter param, **kwargs):
        # Optional different method for aggregating across time.
        temporal_agg_func = kwargs.pop('temporal_agg_func', 'mean')
        super(NumpyArrayIndexParameterRecorder, self).__init__(model, param, **kwargs)

        self._temporal_aggregator = Aggregator(temporal_agg_func)

    property temporal_agg_func:
        def __set__(self, agg_func):
            self._temporal_aggregator.func = agg_func

    cpdef setup(self):
        cdef int ncomb = len(self.model.scenarios.combinations)
        cdef int nts = len(self.model.timestepper)
        self._data = np.zeros((nts, ncomb), dtype=np.int32)

    cpdef reset(self):
        self._data[:, :] = 0

    cpdef after(self):
        cdef int i
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        self._data[ts._index, :] = self._param.get_all_indices()
        return 0

    property data:
        def __get__(self, ):
            return np.array(self._data)

    def to_dataframe(self):
        """ Return a `pandas.DataFrame` of the recorder data
        This DataFrame contains a MultiIndex for the columns with the recorder name
        as the first level and scenario combination names as the second level. This
        allows for easy combination with multiple recorder's DataFrames
        """
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex

        return pd.DataFrame(data=np.array(self._data), index=index, columns=sc_index)
NumpyArrayIndexParameterRecorder.register()


cdef class RollingWindowParameterRecorder(ParameterRecorder):
    """Records the mean value of a Parameter for the last N timesteps.
    """
    def __init__(self, model, Parameter param, int window, *args, **kwargs):

        if "agg_func" in kwargs and "temporal_agg_func" not in kwargs:
            # Support previous behaviour
            warnings.warn('The "agg_func" key is deprecated for defining the temporal '
                          'aggregation in {}. Please "temporal_agg_func" instead.'
                          .format(self.__class__.__name__))
            temporal_agg_func = kwargs.get("agg_func")
        else:
            temporal_agg_func = kwargs.pop("temporal_agg_func", "mean")

        super(RollingWindowParameterRecorder, self).__init__(model, param, *args, **kwargs)
        self.window = window
        self._temporal_aggregator = Aggregator(temporal_agg_func)

    property temporal_agg_func:
        def __set__(self, agg_func):
            self._temporal_aggregator.func = agg_func

    cpdef setup(self):
        cdef int ncomb = len(self.model.scenarios.combinations)
        cdef int nts = len(self.model.timestepper)
        self._data = np.zeros((nts, ncomb,), np.float64)
        self._memory = np.empty((nts, ncomb,), np.float64)
        self.position = 0

    cpdef reset(self):
        self._data[...] = 0
        self.position = 0

    cpdef after(self):
        cdef int i, n
        cdef double[:] value
        cdef ScenarioIndex scenario_index
        cdef Timestep timestep = self.model.timestepper.current

        for i, scenario_index in enumerate(self.model.scenarios.combinations):
            self._memory[self.position, i] = self._param.get_value(scenario_index)

        if timestep._index < self.window:
            n = timestep._index + 1
        else:
            n = self.window

        value = self._temporal_aggregator.aggregate_2d(self._memory[0:n, :], axis=0)
        self._data[timestep._index, :] = value

        self.position += 1
        if self.position >= self.window:
            self.position = 0

    property data:
        def __get__(self):
            return np.array(self._data, dtype=np.float64)

    def to_dataframe(self):
        index = self.model.timestepper.datetime_index
        sc_index = self.model.scenarios.multiindex
        return pd.DataFrame(data=self.data, index=index, columns=sc_index)

    @classmethod
    def load(cls, model, data):
        from pywr.parameters import load_parameter
        parameter = load_parameter(model, data.pop("parameter"))
        window = int(data.pop("window"))
        return cls(model, parameter, window, **data)

RollingWindowParameterRecorder.register()

cdef class RollingMeanFlowNodeRecorder(NodeRecorder):
    """Records the mean flow of a Node for the previous N timesteps

    Parameters
    ----------
    model : `pywr.core.Model`
    node : `pywr.core.Node`
        The node to record
    timesteps : int
        The number of timesteps to calculate the mean flow for
    name : str (optional)
        The name of the recorder

    """
    def __init__(self, model, node, timesteps=None, days=None, name=None, **kwargs):
        super(RollingMeanFlowNodeRecorder, self).__init__(model, node, name=name, **kwargs)
        self.model = model
        if not timesteps and not days:
            raise ValueError("Either `timesteps` or `days` must be specified.")
        if timesteps:
            self.timesteps = int(timesteps)
        else:
            self.timesteps = 0
        if days:
            self.days = int(days)
        else:
            self.days = 0
        self._data = None

    cpdef setup(self):
        super(RollingMeanFlowNodeRecorder, self).setup()
        self.position = 0
        self._data = np.empty([len(self.model.timestepper), len(self.model.scenarios.combinations)])
        if self.days:
            self.timesteps = self.days // self.model.timestepper.delta.days
        if self.timesteps == 0:
            raise ValueError("Timesteps property of MeanFlowRecorder is less than 1.")
        self._memory = np.zeros([len(self.model.scenarios.combinations), self.timesteps])

    cpdef after(self):
        cdef Timestep timestep
        cdef int i, n
        cdef double[:] mean_flow
        # save today's flow
        for i in range(0, self._memory.shape[0]):
            self._memory[i, self.position] = self._node._flow[i]
        # calculate the mean flow
        timestep = self.model.timestepper.current
        if timestep.index < self.timesteps:
            n = timestep.index + 1
        else:
            n = self.timesteps
        # save the mean flow
        mean_flow = np.mean(self._memory[:, 0:n], axis=1)
        self._data[<int>(timestep.index), :] = mean_flow
        # prepare for the next timestep
        self.position += 1
        if self.position >= self.timesteps:
            self.position = 0

    property data:
        def __get__(self):
            return np.array(self._data, dtype=np.float64)

    @classmethod
    def load(cls, model, data):
        name = data.get("name")
        node = model._get_node_from_ref(model, data["node"])
        if "timesteps" in data:
            timesteps = int(data["timesteps"])
        else:
            timesteps = None
        if "days" in data:
            days = int(data["days"])
        else:
            days = None
        return cls(model, node, timesteps=timesteps, days=days, name=name)

RollingMeanFlowNodeRecorder.register()

cdef class BaseConstantNodeRecorder(NodeRecorder):
    """
    Base class for NodeRecorder classes with a single value for each scenario combination
    """

    cpdef setup(self):
        self._values = np.zeros(len(self.model.scenarios.combinations))

    cpdef reset(self):
        self._values[...] = 0.0

    cpdef after(self):
        raise NotImplementedError()

    cpdef double[:] values(self):
        return self._values


cdef class TotalDeficitNodeRecorder(BaseConstantNodeRecorder):
    """
    Recorder to total the difference between modelled flow and max_flow for a Node
    """
    cpdef after(self):
        cdef double max_flow
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        cdef int days = self.model.timestepper.current.days
        cdef AbstractNode node = self._node
        for scenario_index in self.model.scenarios.combinations:
            max_flow = node.get_max_flow(scenario_index)
            self._values[scenario_index.global_id] += (max_flow - node._flow[scenario_index.global_id])*days

        return 0
TotalDeficitNodeRecorder.register()


cdef class TotalFlowNodeRecorder(BaseConstantNodeRecorder):
    """
    Recorder to total the flow for a Node.

    A factor can be provided to scale the total flow (e.g. for calculating operational costs).
    """
    def __init__(self, *args, **kwargs):
        self.factor = kwargs.pop('factor', 1.0)
        super(TotalFlowNodeRecorder, self).__init__(*args, **kwargs)

    cpdef after(self):
        cdef ScenarioIndex scenario_index
        cdef int i
        cdef int days = self.model.timestepper.current.days
        for scenario_index in self.model.scenarios.combinations:
            i = scenario_index.global_id
            self._values[i] += self._node._flow[i]*self.factor*days
        return 0
TotalFlowNodeRecorder.register()


cdef class MeanFlowNodeRecorder(BaseConstantNodeRecorder):
    """
    Record the mean flow for a Node.

    A factor can be provided to scale the total flow (e.g. for calculating operational costs).
    """
    def __init__(self, *args, **kwargs):
        self.factor = kwargs.pop('factor', 1.0)
        super(MeanFlowNodeRecorder, self).__init__(*args, **kwargs)

    cpdef after(self):
        cdef ScenarioIndex scenario_index
        cdef int i
        for scenario_index in self.model.scenarios.combinations:
            i = scenario_index.global_id
            self._values[i] += self._node._flow[i]*self.factor
        return 0

    cpdef finish(self):
        cdef int i
        cdef int nt = self.model.timestepper.current.index
        for i in range(self._values.shape[0]):
            self._values[i] /= nt
MeanFlowNodeRecorder.register()


cdef class DeficitFrequencyNodeRecorder(BaseConstantNodeRecorder):
    """Recorder to return the frequency of timesteps with a failure to meet max_flow.
    """
    cpdef after(self):
        cdef double max_flow
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current
        cdef AbstractNode node = self._node
        for scenario_index in self.model.scenarios.combinations:
            max_flow = node.get_max_flow(scenario_index)
            if abs(node._flow[scenario_index.global_id] - max_flow) > 1e-6:
                self._values[scenario_index.global_id] += 1.0

    cpdef finish(self):
        cdef int i
        cdef int nt = self.model.timestepper.current.index
        for i in range(self._values.shape[0]):
            self._values[i] /= nt
DeficitFrequencyNodeRecorder.register()

cdef class BaseConstantStorageRecorder(StorageRecorder):
    """
    Base class for StorageRecorder classes with a single value for each scenario combination
    """

    cpdef setup(self):
        self._values = np.zeros(len(self.model.scenarios.combinations))

    cpdef reset(self):
        self._values[...] = 0.0

    cpdef after(self):
        raise NotImplementedError()

    cpdef double[:] values(self):
        return self._values
BaseConstantStorageRecorder.register()

cdef class MinimumVolumeStorageRecorder(BaseConstantStorageRecorder):
    """Record the minimum volume in a `Storage` node during a simulation."""
    cpdef reset(self):
        self._values[...] = np.inf

    cpdef after(self):
        cdef int i
        for i in range(self._values.shape[0]):
            self._values[i] = np.min([self._node._volume[i], self._values[i]])
        return 0
MinimumVolumeStorageRecorder.register()

cdef class MinimumThresholdVolumeStorageRecorder(BaseConstantStorageRecorder):
    """Record whether a `Storage` node falls below a particular volume threshold during a simulation.

    This recorder will return a value of `1.0` for scenarios where the volume `Storage` is less
    than or equal to the threshold at any time-step during the simulation. Otherwise it will return zero.
    """
    def __init__(self, model, node, threshold, *args, **kwargs):
        self.threshold = threshold
        super(MinimumThresholdVolumeStorageRecorder, self).__init__(model, node, *args, **kwargs)

    cpdef reset(self):
        self._values[...] = 0.0

    cpdef after(self):
        cdef int i
        for i in range(self._values.shape[0]):
            if self._node._volume[i] <= self.threshold:
                self._values[i] = 1.0
        return 0
MinimumThresholdVolumeStorageRecorder.register()


cdef class AnnualCountIndexParameterRecorder(IndexParameterRecorder):
    """ Record the number of years where an IndexParameter is greater than or equal to a threshold """
    def __init__(self, model, IndexParameter param, int threshold, *args, **kwargs):
        super(AnnualCountIndexParameterRecorder, self).__init__(model, param, *args, **kwargs)
        self.threshold = threshold

    cpdef setup(self):
        self._count = np.zeros(len(self.model.scenarios.combinations), np.int32)
        self._current_max = np.zeros_like(self._count)

    cpdef reset(self):
        self._count[...] = 0
        self._current_max[...] = 0
        self._current_year = -1

    cpdef after(self):
        cdef int i, ncomb, value
        cdef ScenarioIndex scenario_index
        cdef Timestep ts = self.model.timestepper.current

        ncomb = len(self.model.scenarios.combinations)

        if ts.year != self._current_year:
            # A new year
            if self._current_year != -1:
                # As long as at least one year has been run
                # then update the count if threshold equal to or exceeded
                for i in range(ncomb):
                    if self._current_max[i] >= self.threshold:
                        self._count[i] += 1

            # Finally reset current maximum and update current year
            self._current_max[...] = 0
            self._current_year = ts.year

        for scenario_index in self.model.scenarios.combinations:
            # Get current parameter value
            value = self._param.get_index(scenario_index)

            # Update annual max if a new maximum is found
            if value > self._current_max[scenario_index.global_id]:
                self._current_max[scenario_index.global_id] = value

        return 0

    cpdef finish(self):
        cdef int i
        cdef int ncomb = len(self.model.scenarios.combinations)
        # Complete the current year by updating the count if threshold equal to or exceeded
        for i in range(ncomb):
            if self._current_max[i] >= self.threshold:
                self._count[i] += 1

    cpdef double[:] values(self):
        return np.asarray(self._count).astype(np.float64)
AnnualCountIndexParameterRecorder.register()


def load_recorder(model, data):
    recorder = None

    if isinstance(data, basestring):
        recorder_name = data
    else:
        recorder_name = None

    # check if recorder has already been loaded
    for rec in model.recorders:
        if rec.name == recorder_name:
            recorder = rec
            break

    if recorder is None and isinstance(data, basestring):
        # recorder was requested by name, but hasn't been loaded yet
        if hasattr(model, "_recorders_to_load"):
            # we're still in the process of loading data from JSON and
            # the parameter requested hasn't been loaded yet - do it now
            try:
                data = model._recorders_to_load[recorder_name]
            except KeyError:
                raise KeyError("Unknown recorder: '{}'".format(data))
            recorder = load_recorder(model, data)
        else:
            raise KeyError("Unknown recorder: '{}'".format(data))

    if recorder is None:
        recorder_type = data['type']

        name = recorder_type.lower()
        try:
            cls = recorder_registry[name]
        except KeyError:
            if name.endswith("recorder"):
                name = name.replace("recorder", "")
            else:
                name += "recorder"
            try:
                cls = recorder_registry[name]
            except KeyError:
                raise NotImplementedError('Unrecognised recorder type "{}"'.format(recorder_type))

        del(data["type"])
        recorder = cls.load(model, data)

    return recorder


cdef class BaseConstantParameterRecorder(ParameterRecorder):
    """Base class for `ParameterRecorder` classes with a single value for each scenario combination
    """
    cpdef setup(self):
        self._values = np.zeros(len(self.model.scenarios.combinations))

    cpdef reset(self):
        self._values[...] = 0.0

    cpdef after(self):
        raise NotImplementedError()

    cpdef double[:] values(self):
        return self._values


cdef class TotalParameterRecorder(BaseConstantParameterRecorder):
    """Record the total value of a `Parameter` during a simulation.

    This recorder can be used to track the sum total of the values returned by a
    `Parameter` during a models simulation. An optional factor can be provided to
    apply a linear scaling of the values. If the parameter represents a flux
    the `integrate` keyword argument can be used to multiply the values by the time-step
    length in days.

    Parameters
    ----------
    model : `pywr.core.Model`
    param : `pywr.parameters.Parameter`
        The parameter to record.
    name : str (optional)
        The name of the recorder
    factor : float (default=1.0)
        Scaling factor for the values of `param`.
    integrate : bool (default=False)
        Whether to multiply by the time-step length in days during summation.
    """
    def __init__(self, *args, **kwargs):
        self.factor = kwargs.pop('factor', 1.0)
        self.integrate = kwargs.pop('integrate', False)
        super(TotalParameterRecorder, self).__init__(*args, **kwargs)

    cpdef after(self):
        cdef ScenarioIndex scenario_index
        cdef int i
        cdef double[:] values
        cdef factor = self.factor

        if self.integrate:
            factor *= self.model.timestepper.current.days

        values = self._param.get_all_values()
        for scenario_index in self.model.scenarios.combinations:
            i = scenario_index.global_id
            self._values[i] += values[i]*factor
        return 0
TotalParameterRecorder.register()


cdef class MeanParameterRecorder(BaseConstantParameterRecorder):
    """Record the mean value of a `Parameter` during a simulation.

    This recorder can be used to track the sum total of the values returned by a
    `Parameter` during a models simulation. An optional factor can be provided to
    apply a linear scaling of the values. If the parameter represents a flux
    the `integrate` keyword argument can be used to multiply the values by the time-step
    length in days.

    Parameters
    ----------
    model : `pywr.core.Model`
    param : `pywr.parameters.Parameter`
        The parameter to record.
    name : str (optional)
        The name of the recorder
    factor : float (default=1.0)
        Scaling factor for the values of `param`.
    """
    def __init__(self, *args, **kwargs):
        self.factor = kwargs.pop('factor', 1.0)
        super(MeanParameterRecorder, self).__init__(*args, **kwargs)

    cpdef after(self):
        cdef ScenarioIndex scenario_index
        cdef int i
        cdef double[:] values
        cdef factor = self.factor

        values = self._param.get_all_values()
        for scenario_index in self.model.scenarios.combinations:
            i = scenario_index.global_id
            self._values[i] += values[i]*factor
        return 0

    cpdef finish(self):
        cdef int i
        cdef int nt = self.model.timestepper.current.index
        for i in range(self._values.shape[0]):
            self._values[i] /= nt
MeanParameterRecorder.register()
